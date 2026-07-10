#!/usr/bin/env python3
"""
Intake packet processor for the Round Rock Fitness Tracker.

Consumes the JSON files Power Automate drops in the OneDrive intake dropbox
(one file per Microsoft Forms Pre-Assessment response) and lands each one as
a client in Supabase (intake-v2 shape in clients.intake_paperwork, rendered
read-only in ClientDetail since v4.43).

DESIGN POSTURE (CHANGED 2026-07-10 - was read-only/emit-SQL):
  This script now WRITES to Supabase. New-client intakes are the primary
  case: an unmatched, validated response is POSTed as a new clients row.
  An intake that matches an existing client (dedup hit on email/phone) does
  NOT create a duplicate - it PATCHes that client's intake_paperwork instead.
  Writes go through the REST API with the key in SUPABASE_ANON_KEY (RLS is
  disabled project-wide, so the key is what authorizes the write).

  intake_paperwork carries health-screening answers (PHI). Two guards keep
  this honest: (1) --dry-run performs ZERO writes and just reports what it
  would do - always test a batch dry first; (2) validation is strict, so a
  junk response can never mint a client (see validate_new).

WHAT IT DOES PER RUN (one-shot; Task Scheduler, don't daemonize):
  - Scans WATCH_DIR for *.json (ignores archive/ and review/)
  - Per file: validate shape, normalize Yes/No -> booleans and dates -> ISO
  - Match to a client: unique email match, else unique phone match.
  - Matched   -> PATCH intake_paperwork on that client (no duplicate)
  - Unmatched + valid (name + real email/phone) -> POST new client
  - Unmatched + invalid, or ambiguous match -> review/ + review CSV row
  - Source file -> archive/ ; manifest line appended either way

USAGE:
  python intake_import.py --watch-dir "C:\\...\\intake_dropbox" --dry-run
  python intake_import.py --watch-dir "C:\\...\\intake_dropbox"

ENV:
  SUPABASE_URL       (default: the project URL below)
  SUPABASE_ANON_KEY  (required; authorizes the read + writes)

No third-party dependencies. Standard library only.
"""

import argparse
import csv
import datetime as dt
import json
import logging
import os
import re
import shutil
import sys
import uuid
import urllib.request
import urllib.error

DEFAULT_SUPABASE_URL = "https://ofezaezijafglyjmisgz.supabase.co"

# intake-v2 boolean keys, by section. Forms sends "Yes"/"No" strings; the app
# render coerces defensively, but stored rows should carry real booleans.
BOOL_KEYS = {
    "participant": ["consent"],
    "health_screen": [
        "heart_condition_bp", "chest_pain_activity", "chest_pain_rest",
        "dizziness_balance", "bone_joint_problem", "bp_heart_medication",
        "pregnant_postpartum", "breathing_issues", "surgery_last_year",
        "diabetes_cholesterol", "other_contraindication",
    ],
    "lifestyle": ["nicotine", "alcohol"],
}
DATE_KEYS = {"participant": ["dob"]}
TOP_DATE_KEYS = ["completed_date"]

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

log = logging.getLogger("intake_import")


def to_bool(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("yes", "true", "y", "1"):
            return True
        if s in ("no", "false", "n", "0"):
            return False
    return None  # unanswered / unparseable -> key dropped


def to_iso_date(v):
    """Accept ISO already, or M/D/YYYY (with optional 12h/24h time) from Forms."""
    if not v or not isinstance(v, str):
        return None
    v = v.strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y",
                "%m/%d/%Y %H:%M", "%m/%d/%Y %H:%M:%S",
                "%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %I:%M %p"):
        try:
            return dt.datetime.strptime(v, fmt).date().isoformat()
        except ValueError:
            continue
    # last resort: ISO datetime string
    try:
        return dt.datetime.fromisoformat(v.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        return None


def digits(s):
    return re.sub(r"\D", "", s or "")


def facility_to_location(f):
    """Map the Forms facility label to the clients.location value."""
    s = (f or "").strip().lower()
    if "baca" in s:
        return "Baca"
    if "madsen" in s or "clay" in s or "cmrc" in s:
        return "CMRC"
    return None


def normalize(payload):
    """Coerce booleans and dates in place; drop empty strings. Returns notes."""
    notes = []
    for sec, keys in BOOL_KEYS.items():
        d = payload.get(sec)
        if not isinstance(d, dict):
            continue
        for k in keys:
            if k in d:
                b = to_bool(d[k])
                if b is None:
                    d.pop(k)
                else:
                    d[k] = b
    for sec, keys in DATE_KEYS.items():
        d = payload.get(sec)
        if not isinstance(d, dict):
            continue
        for k in keys:
            if d.get(k):
                iso = to_iso_date(str(d[k]))
                if iso:
                    d[k] = iso
                else:
                    notes.append("unparseable date %s.%s=%r" % (sec, k, d[k]))
    for k in TOP_DATE_KEYS:
        if payload.get(k):
            iso = to_iso_date(str(payload[k]))
            if iso:
                payload[k] = iso
    # drop empty-string leaves so the render's skip-blank logic never sees ''
    for sec, d in list(payload.items()):
        if isinstance(d, dict):
            for k in list(d.keys()):
                if d[k] == "":
                    d.pop(k)
    return notes


def fetch_clients(base_url, key):
    """READ-ONLY. Pull id/name/email/phone for matching. Paged just in case."""
    out, start, page = [], 0, 1000
    while True:
        req = urllib.request.Request(
            base_url.rstrip("/")
            + "/rest/v1/clients?select=id,name,email,phone&deleted_at=is.null",
            headers={
                "apikey": key,
                "Authorization": "Bearer " + key,
                "Range": "%d-%d" % (start, start + page - 1),
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
        out.extend(rows)
        if len(rows) < page:
            return out
        start += page


def match_client(payload, clients):
    """Return (client, reason) or (None, reason). Unique email, else unique
    phone. Name-only is NEVER auto-matched. A multi-hit is ambiguous -> review
    (caller must not create on an ambiguous reason)."""
    part = payload.get("participant") or {}
    email = (part.get("email") or "").strip().lower()
    phone = digits(part.get("phone"))
    if email:
        hits = [c for c in clients if (c.get("email") or "").strip().lower() == email]
        if len(hits) == 1:
            return hits[0], "email"
        if len(hits) > 1:
            return None, "AMBIGUOUS: email matched %d clients" % len(hits)
    if len(phone) >= 10:
        hits = [c for c in clients if digits(c.get("phone")) == phone]
        if len(hits) == 1:
            return hits[0], "phone"
        if len(hits) > 1:
            return None, "AMBIGUOUS: phone matched %d clients" % len(hits)
    return None, "no existing match"


def validate_new(payload):
    """Gate a brand-new client: name required, plus a real email OR a 10-digit
    phone. Returns (ok, reason). Junk responses fail here and route to review -
    they must never mint a client."""
    part = payload.get("participant") or {}
    name = (part.get("name") or "").strip()
    email = (part.get("email") or "").strip()
    phone = digits(part.get("phone"))
    if not name:
        return False, "missing name"
    has_email = bool(email) and bool(EMAIL_RE.match(email))
    has_phone = len(phone) >= 10
    if not has_email and not has_phone:
        return False, "no valid email or 10-digit phone"
    return True, "ok"


def _client_row(payload):
    """Build the clients insert row from a normalized intake payload."""
    part = payload.get("participant") or {}
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    row = {
        "id": str(uuid.uuid4()),
        "name": (part.get("name") or "").strip(),
        "email": ((part.get("email") or "").strip() or None),
        "phone": ((part.get("phone") or "").strip() or None),
        "is_active": True,
        "created_by": "MS Forms intake",
        "created_at": now,
        "updated_at": now,
        "intake_paperwork": payload,
    }
    loc = facility_to_location(part.get("facility"))
    if loc:
        row["location"] = loc
    return row


def _write(base_url, key, path, body, method):
    req = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(body).encode("utf-8"),
        method=method,
        headers={
            "apikey": key,
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.loads(resp.read().decode("utf-8"))
    return out[0] if isinstance(out, list) and out else out


def create_client(base_url, key, payload):
    """POST a new clients row. Returns the created row (id populated)."""
    return _write(base_url, key, "/rest/v1/clients", _client_row(payload), "POST")


def update_paperwork(base_url, key, client_id, payload):
    """PATCH intake_paperwork on an existing client (dedup hit). No dup."""
    body = {"intake_paperwork": payload,
            "updated_at": dt.datetime.now(dt.timezone.utc).isoformat()}
    return _write(base_url, key,
                  "/rest/v1/clients?id=eq." + client_id, body, "PATCH")


def _http_err(ex):
    try:
        return "%s %s" % (ex.code, ex.read().decode("utf-8", "replace")[:300])
    except Exception:
        return str(ex)


def process(watch_dir, base_url, key, dry_run=False):
    today = dt.date.today().isoformat()
    archive = os.path.join(watch_dir, "archive")
    review = os.path.join(watch_dir, "review")
    review_csv = os.path.join(watch_dir, "review_%s.csv" % today)
    manifest = os.path.join(watch_dir, "manifest.log")

    files = sorted(
        f for f in os.listdir(watch_dir)
        if f.lower().endswith(".json") and os.path.isfile(os.path.join(watch_dir, f))
    )
    if not files:
        log.info("nothing to process")
        return 0

    clients = fetch_clients(base_url, key)
    log.info("matching against %d active clients%s",
             len(clients), " (DRY RUN - no writes)" if dry_run else "")
    if not dry_run:
        os.makedirs(archive, exist_ok=True)
        os.makedirs(review, exist_ok=True)

    created = updated = flagged = 0
    for fname in files:
        src = os.path.join(watch_dir, fname)
        payload, reason, bad = None, None, False
        try:
            with open(src, encoding="utf-8-sig") as fh:
                payload = json.load(fh)
        except (ValueError, OSError) as ex:
            reason, bad = "unreadable JSON: %s" % ex, True
            log.warning("%s: %s -> review", fname, reason)

        if payload is not None:
            if payload.get("version") != "intake-v2":
                reason, bad = "version %r != intake-v2" % payload.get("version"), True
                log.warning("%s: %s -> review", fname, reason)
            else:
                for n in normalize(payload):
                    log.warning("%s: %s", fname, n)

        # Decide the action for this file.
        action, client, reason = "review", None, (reason or "")
        if not bad:
            client, mreason = match_client(payload, clients)
            if client:
                action, reason = "update", mreason
            elif mreason.startswith("AMBIGUOUS"):
                action, reason = "review", mreason
            else:
                ok, vreason = validate_new(payload)
                action = "create" if ok else "review"
                reason = "new client" if ok else vreason

        part = (payload or {}).get("participant") or {}
        line = None
        try:
            if action == "update":
                updated += 1
                if dry_run:
                    log.info("%s -> would UPDATE %s (matched on %s)",
                             fname, client.get("name"), reason)
                else:
                    update_paperwork(base_url, key, client["id"], payload)
                    shutil.move(src, os.path.join(archive, fname))
                    log.info("%s -> UPDATED %s (matched on %s)",
                             fname, client.get("name"), reason)
                line = "%s\t%s\tupdated(%s)\t%s" % (today, fname, reason, client["id"])

            elif action == "create":
                created += 1
                if dry_run:
                    log.info("%s -> would CREATE new client %r (%s / %s)",
                             fname, part.get("name"), part.get("email") or "-",
                             part.get("phone") or "-")
                else:
                    row = create_client(base_url, key, payload)
                    shutil.move(src, os.path.join(archive, fname))
                    log.info("%s -> CREATED %s id=%s",
                             fname, part.get("name"), (row or {}).get("id"))
                line = "%s\t%s\tcreated\t%s" % (today, fname, part.get("name") or "?")

            else:  # review
                flagged += 1
                if not dry_run:
                    new_row = not os.path.exists(review_csv)
                    with open(review_csv, "a", newline="", encoding="utf-8") as fh:
                        w = csv.writer(fh)
                        if new_row:
                            w.writerow(["file", "name", "email", "phone", "reason"])
                        w.writerow([fname, part.get("name", ""), part.get("email", ""),
                                    part.get("phone", ""), reason])
                    shutil.move(src, os.path.join(review, fname))
                log.info("%s -> review (%s)", fname, reason)
                line = "%s\t%s\tREVIEW\t%s" % (today, fname, reason)

        except urllib.error.HTTPError as ex:
            # A write failed: back the counter out, quarantine to review.
            if action == "update":
                updated -= 1
            elif action == "create":
                created -= 1
            flagged += 1
            log.error("%s: %s FAILED (%s) -> left in place for retry",
                      fname, action, _http_err(ex))
            line = "%s\t%s\tERROR(%s)\t%s" % (today, fname, action, _http_err(ex))

        if not dry_run and line:
            with open(manifest, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    log.info("done: %d created, %d updated, %d for review%s",
             created, updated, flagged,
             " (DRY RUN, nothing written)" if dry_run else "")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--watch-dir", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    key = os.environ.get("SUPABASE_ANON_KEY")
    if not key:
        log.error("SUPABASE_ANON_KEY not set")
        return 2
    base_url = os.environ.get("SUPABASE_URL", DEFAULT_SUPABASE_URL)
    if not os.path.isdir(args.watch_dir):
        log.error("watch dir does not exist: %s", args.watch_dir)
        return 2
    return process(args.watch_dir, base_url, key, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
