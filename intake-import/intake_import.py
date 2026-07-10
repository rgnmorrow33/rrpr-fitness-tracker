#!/usr/bin/env python3
"""
Intake packet processor for the Round Rock Fitness Tracker.

Consumes the JSON files Power Automate drops in the OneDrive intake dropbox
(one file per Microsoft Forms Pre-Assessment response), matches each response
to a client in Supabase, and emits a reviewed SQL file that sets
clients.intake_paperwork (intake-v2 shape, rendered read-only in ClientDetail
since v4.43).

DESIGN POSTURE (same as rectrac_import.py - read before changing):
  This script does NOT write to Supabase. Matching uses a READ-ONLY GET
  against the REST API with the anon key. The actual UPDATE stays in
  Reagan's lane: review the emitted .sql file, paste it in the Supabase SQL
  editor. Promote to auto-write only after the credential/RLS question is
  resolved (intake_paperwork carries health-screening data - see the PHI
  note in CLAUDE.md Security posture).

WHAT IT DOES PER RUN (one-shot; Task Scheduler, don't daemonize):
  - Scans WATCH_DIR for *.json (ignores archive/ and review/)
  - Per file: validate shape, normalize Yes/No -> booleans and dates -> ISO
  - Match to a client: unique email match, else unique phone match.
    Name-only or ambiguous or zero matches -> review lane, never guessed.
  - Matched   -> UPDATE appended to intake_updates_YYYY-MM-DD.sql
  - Unmatched -> copied to review/ + row in review_YYYY-MM-DD.csv
  - Source file -> archive/ ; manifest line appended either way

USAGE:
  python intake_import.py --watch-dir "C:\\Users\\rmorrow\\OneDrive - City of Round Rock\\Docs\\intake_dropbox"
  python intake_import.py --watch-dir "..." --dry-run

ENV:
  SUPABASE_URL       (default: the project URL below)
  SUPABASE_ANON_KEY  (required; same designed-public key the app ships)

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
import urllib.request
import urllib.error

DEFAULT_SUPABASE_URL = "https://ofezaezijafglyjmisgz.supabase.co"

# intake-v2 boolean keys, by section. Forms sends "Yes"/"No" strings; the app
# render coerces defensively, but SQL rows should carry real booleans.
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
    """Accept ISO already, or M/D/YYYY from Forms. Return None if hopeless."""
    if not v or not isinstance(v, str):
        return None
    v = v.strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%m/%d/%Y %H:%M", "%m/%d/%Y %H:%M:%S"):
        try:
            return dt.datetime.strptime(v.split("T")[0] if "T" in v else v, fmt).date().isoformat()
        except ValueError:
            continue
    # last resort: ISO datetime string
    try:
        return dt.datetime.fromisoformat(v.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        return None


def digits(s):
    return re.sub(r"\D", "", s or "")


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


def fetch_clients(base_url, anon_key):
    """READ-ONLY. Pull id/name/email/phone for matching. Paged just in case."""
    out, start, page = [], 0, 1000
    while True:
        req = urllib.request.Request(
            base_url.rstrip("/")
            + "/rest/v1/clients?select=id,name,email,phone&deleted_at=is.null",
            headers={
                "apikey": anon_key,
                "Authorization": "Bearer " + anon_key,
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
    phone. Name-only is NEVER auto-matched - review lane."""
    part = payload.get("participant") or {}
    email = (part.get("email") or "").strip().lower()
    phone = digits(part.get("phone"))
    if email:
        hits = [c for c in clients if (c.get("email") or "").strip().lower() == email]
        if len(hits) == 1:
            return hits[0], "email"
        if len(hits) > 1:
            return None, "email matched %d clients" % len(hits)
    if len(phone) >= 10:
        hits = [c for c in clients if digits(c.get("phone")) == phone]
        if len(hits) == 1:
            return hits[0], "phone"
        if len(hits) > 1:
            return None, "phone matched %d clients" % len(hits)
    name = (part.get("name") or "").strip().lower()
    if name and any((c.get("name") or "").strip().lower() == name for c in clients):
        return None, "name-only candidate - confirm manually"
    return None, "no match on email/phone/name"


def sql_update(client, payload, reason):
    body = json.dumps(payload, indent=2, ensure_ascii=False)
    tag = "$intake_json$"
    if tag in body:  # can't happen with Forms text, but never emit broken SQL
        body = json.dumps(payload, ensure_ascii=True)
    part = payload.get("participant") or {}
    return (
        "-- %s  (form: %s, response %s, matched on %s)\n"
        "UPDATE clients\n"
        "SET intake_paperwork = %s\n%s\n%s::jsonb\n"
        "WHERE id = '%s' AND deleted_at IS NULL;\n"
        % (
            client.get("name") or "?",
            part.get("name") or "?",
            payload.get("response_id", "?"),
            reason,
            tag, body, tag,
            client["id"],
        )
    )


def process(watch_dir, base_url, anon_key, dry_run=False):
    today = dt.date.today().isoformat()
    archive = os.path.join(watch_dir, "archive")
    review = os.path.join(watch_dir, "review")
    sql_path = os.path.join(watch_dir, "intake_updates_%s.sql" % today)
    review_csv = os.path.join(watch_dir, "review_%s.csv" % today)
    manifest = os.path.join(watch_dir, "manifest.log")

    files = sorted(
        f for f in os.listdir(watch_dir)
        if f.lower().endswith(".json") and os.path.isfile(os.path.join(watch_dir, f))
    )
    if not files:
        log.info("nothing to process")
        return 0

    clients = fetch_clients(base_url, anon_key)
    log.info("matching against %d active clients", len(clients))
    if not dry_run:
        os.makedirs(archive, exist_ok=True)
        os.makedirs(review, exist_ok=True)

    matched, flagged = 0, 0
    for fname in files:
        src = os.path.join(watch_dir, fname)
        try:
            with open(src, encoding="utf-8-sig") as fh:
                payload = json.load(fh)
        except (ValueError, OSError) as ex:
            log.warning("%s: unreadable JSON (%s) -> review", fname, ex)
            payload, reason = None, "unreadable JSON: %s" % ex

        if payload is not None:
            if payload.get("version") != "intake-v2":
                log.warning("%s: version %r is not intake-v2 -> review",
                            fname, payload.get("version"))
                reason = "version %r != intake-v2" % payload.get("version")
                payload_bad = True
            else:
                payload_bad = False
                notes = normalize(payload)
                for n in notes:
                    log.warning("%s: %s", fname, n)
                client, reason = match_client(payload, clients)

        line = None
        if payload is not None and not payload_bad and client:
            matched += 1
            if not dry_run:
                with open(sql_path, "a", encoding="utf-8") as fh:
                    fh.write(sql_update(client, payload, reason) + "\n")
                shutil.move(src, os.path.join(archive, fname))
            line = "%s\t%s\tmatched(%s)\t%s" % (today, fname, reason, client["id"])
            log.info("%s -> matched %s on %s", fname, client.get("name"), reason)
        else:
            flagged += 1
            if not dry_run:
                new_row = not os.path.exists(review_csv)
                with open(review_csv, "a", newline="", encoding="utf-8") as fh:
                    w = csv.writer(fh)
                    if new_row:
                        w.writerow(["file", "name", "email", "phone", "reason"])
                    part = (payload or {}).get("participant") or {}
                    w.writerow([fname, part.get("name", ""), part.get("email", ""),
                                part.get("phone", ""), reason])
                shutil.move(src, os.path.join(review, fname))
            line = "%s\t%s\tREVIEW\t%s" % (today, fname, reason)
            log.info("%s -> review (%s)", fname, reason)

        if not dry_run and line:
            with open(manifest, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    log.info("done: %d matched -> %s ; %d for review -> %s%s",
             matched, os.path.basename(sql_path), flagged,
             os.path.basename(review_csv), " (DRY RUN, nothing written)" if dry_run else "")
    if matched and not dry_run:
        log.info("NEXT STEP: review %s, then run it in the Supabase SQL editor",
                 os.path.basename(sql_path))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--watch-dir", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    anon_key = os.environ.get("SUPABASE_ANON_KEY")
    if not anon_key:
        log.error("SUPABASE_ANON_KEY not set (use the app's designed-public anon key)")
        return 2
    base_url = os.environ.get("SUPABASE_URL", DEFAULT_SUPABASE_URL)
    if not os.path.isdir(args.watch_dir):
        log.error("watch dir does not exist: %s", args.watch_dir)
        return 2
    return process(args.watch_dir, base_url, anon_key, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
