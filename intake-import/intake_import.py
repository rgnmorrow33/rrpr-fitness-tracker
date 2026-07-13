#!/usr/bin/env python3
"""
Intake packet processor for the Round Rock Fitness Tracker.

Consumes the JSON files Power Automate drops in the OneDrive intake dropbox
(one file per Microsoft Forms Pre-Assessment response) and lands each one as
a CLIENT plus a linked consult-queue LEAD in Supabase.

DESIGN POSTURE (CHANGED 2026-07-10 - was read-only/emit-SQL):
  This script WRITES to Supabase. Per response it provisions BOTH:
    - a client row carrying intake_paperwork (intake-v2 JSONB, rendered in
      ClientDetail), and
    - a `waiting` lead in the consult queue (source ms_forms) linked back via
      client.from_queue_id = lead.id, so a trainer picks it up and reads the
      full packet in LeadDetailModal during the consult (v4.44).
  Writes go through the REST API with the key in SUPABASE_ANON_KEY (RLS is
  disabled project-wide, so the key authorizes the write). intake_paperwork
  carries health-screening answers (PHI): --dry-run performs ZERO writes and
  just reports the plan; validation is strict so junk can never mint records.

DEDUP (idempotent-ish; a partial-failure retry self-heals via these rules):
  - Matches an existing client (unique email, else unique phone) -> PATCH that
    client's intake_paperwork. Add a fresh waiting lead only if they have no
    open lead already. Never duplicates a client.
  - No client match, valid new person -> CREATE client + link it to a lead. If
    an OPEN lead already matches (waiting/assigned/contacted/consult_scheduled)
    reuse it; else create a new one.
  - Junk / unreadable / not intake-v2 / ambiguous match -> review lane, no write.

WHAT IT DOES PER RUN (one-shot; Task Scheduler, don't daemonize):
  - Scans WATCH_DIR for *.json (ignores archive/ and review/)
  - Validates shape, normalizes Yes/No -> booleans and dates -> ISO
  - Applies the dedup rules above; source file -> archive/ on success, left in
    place on a write error (next run heals); review/ + CSV row when flagged

USAGE:
  python intake_import.py --watch-dir "C:\\...\\intake_dropbox" --dry-run
  python intake_import.py --watch-dir "C:\\...\\intake_dropbox"

ENV:
  SUPABASE_URL               (default: the project URL below)
  SUPABASE_SERVICE_ROLE_KEY  (preferred once RLS is live; required after)
  SUPABASE_ANON_KEY          (fallback; sufficient only while RLS is off)

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

# Lead statuses that count as "still in the pipeline" - a person with one of
# these should not get a second queue entry. (converted / lost are closed.)
OPEN_LEAD_STATUSES = ("waiting", "assigned", "contacted", "consult_scheduled")

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


def _get(base_url, key, path):
    """READ-ONLY paged GET. Returns all rows."""
    out, start, page = [], 0, 1000
    while True:
        req = urllib.request.Request(
            base_url.rstrip("/") + path,
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


def fetch_clients(base_url, key):
    return _get(base_url, key,
                "/rest/v1/clients?select=id,name,email,phone,from_queue_id&deleted_at=is.null")


def fetch_leads(base_url, key):
    return _get(base_url, key, "/rest/v1/leads?select=id,name,email,phone,status")


def match_client(payload, clients):
    """Return (client, reason) or (None, reason). Unique email, else unique
    phone. A multi-hit is ambiguous -> review (caller must not create)."""
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


def open_lead_for(payload, leads):
    """Return an existing OPEN lead matching this person (email, else phone),
    so we never stack a second queue entry on someone already in the pipeline."""
    part = payload.get("participant") or {}
    email = (part.get("email") or "").strip().lower()
    phone = digits(part.get("phone"))
    for lead in leads:
        if (lead.get("status") or "waiting") not in OPEN_LEAD_STATUSES:
            continue
        if email and (lead.get("email") or "").strip().lower() == email:
            return lead
        if len(phone) >= 10 and digits(lead.get("phone")) == phone:
            return lead
    return None


def validate_new(payload):
    """Gate a brand-new person: name required, plus a real email OR a 10-digit
    phone. Returns (ok, reason). Junk fails here and routes to review."""
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


def _now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _client_row(payload, from_queue_id=None):
    part = payload.get("participant") or {}
    now = _now()
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
    if from_queue_id:
        row["from_queue_id"] = from_queue_id
    return row


def _lead_row(payload):
    part = payload.get("participant") or {}
    now = _now()
    return {
        "id": str(uuid.uuid4()),
        "name": (part.get("name") or "").strip(),
        "email": ((part.get("email") or "").strip() or None),
        "phone": ((part.get("phone") or "").strip() or None),
        "source": "ms_forms",
        "status": "waiting",
        "added_by": "MS Forms intake",
        "created_by": "MS Forms intake",
        "created_at": now,
        "updated_at": now,
        "status_history": [{
            "from": None, "to": "waiting", "at": now,
            "by": "MS Forms intake", "note": "Intake via Microsoft Forms",
        }],
    }


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


def create_client(base_url, key, payload, from_queue_id=None):
    return _write(base_url, key, "/rest/v1/clients",
                  _client_row(payload, from_queue_id), "POST")


def create_lead(base_url, key, payload):
    return _write(base_url, key, "/rest/v1/leads", _lead_row(payload), "POST")


def patch_client(base_url, key, client_id, fields):
    body = dict(fields)
    body.setdefault("updated_at", _now())
    return _write(base_url, key, "/rest/v1/clients?id=eq." + client_id, body, "PATCH")


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
    leads = fetch_leads(base_url, key)
    log.info("matching against %d active clients, %d leads%s",
             len(clients), len(leads), " (DRY RUN - no writes)" if dry_run else "")
    if not dry_run:
        os.makedirs(archive, exist_ok=True)
        os.makedirs(review, exist_ok=True)

    created = updated = leads_made = flagged = 0
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

        # Decide the action.
        action, client, reason = "review", None, (reason or "")
        existing_lead = None
        if not bad:
            client, mreason = match_client(payload, clients)
            existing_lead = open_lead_for(payload, leads)
            if client:
                action, reason = "update_client", mreason
            elif mreason.startswith("AMBIGUOUS"):
                action, reason = "review", mreason
            else:
                ok, vreason = validate_new(payload)
                action = "create_client" if ok else "review"
                reason = "new person" if ok else vreason

        part = (payload or {}).get("participant") or {}
        name = part.get("name") or "?"
        line = None
        try:
            if action == "update_client":
                if dry_run:
                    tail = "(open lead exists)" if existing_lead else "+ new lead"
                    log.info("%s -> would UPDATE paperwork on %s [%s] %s",
                             fname, client.get("name"), reason, tail)
                else:
                    patch_client(base_url, key, client["id"], {"intake_paperwork": payload})
                    made = ""
                    if not existing_lead:
                        lead = create_lead(base_url, key, payload)
                        patch_client(base_url, key, client["id"], {"from_queue_id": lead["id"]})
                        leads_made += 1
                        made = " + lead %s" % lead["id"]
                    shutil.move(src, os.path.join(archive, fname))
                    log.info("%s -> UPDATED paperwork on %s%s", fname, client.get("name"), made)
                updated += 1
                line = "%s\t%s\tupdated(%s)\t%s" % (today, fname, reason, client["id"])

            elif action == "create_client":
                if dry_run:
                    tail = "(reuse open lead)" if existing_lead else "+ new lead"
                    log.info("%s -> would CREATE client %r (%s / %s) %s",
                             fname, name, part.get("email") or "-", part.get("phone") or "-", tail)
                else:
                    if existing_lead:
                        lead_id = existing_lead["id"]
                    else:
                        lead = create_lead(base_url, key, payload)
                        lead_id = lead["id"]
                        leads_made += 1
                    row = create_client(base_url, key, payload, from_queue_id=lead_id)
                    shutil.move(src, os.path.join(archive, fname))
                    log.info("%s -> CREATED %s id=%s lead=%s",
                             fname, name, (row or {}).get("id"), lead_id)
                created += 1
                line = "%s\t%s\tcreated\t%s" % (today, fname, name)

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
            # A write failed: leave the file in place so the next run heals it
            # (dedup makes a retry converge instead of duplicating).
            flagged += 1
            log.error("%s: %s FAILED (%s) -> left in place for retry",
                      fname, action, _http_err(ex))
            line = "%s\t%s\tERROR(%s)\t%s" % (today, fname, action, _http_err(ex))

        if not dry_run and line:
            with open(manifest, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    log.info("done: %d created, %d paperwork-updated, %d leads made, %d for review%s",
             created, updated, leads_made, flagged,
             " (DRY RUN, nothing written)" if dry_run else "")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--watch-dir", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    # RLS pass (item 3): prefer the service role key when present. The anon
    # key fallback keeps this run-identical until the env var is added. Never
    # commit either key; both live in the runner's environment only.
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_ANON_KEY")
    if not key:
        log.error("SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY not set")
        return 2
    if os.environ.get("SUPABASE_SERVICE_ROLE_KEY"):
        log.info("using service role key")
    base_url = os.environ.get("SUPABASE_URL", DEFAULT_SUPABASE_URL)
    if not os.path.isdir(args.watch_dir):
        log.error("watch dir does not exist: %s", args.watch_dir)
        return 2
    return process(args.watch_dir, base_url, key, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
# item 3 RLS pass: dual-key support added July 2026
