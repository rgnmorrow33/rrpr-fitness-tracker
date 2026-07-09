#!/usr/bin/env python3
"""
RecTrac CSV import processor for the Round Rock Fitness Tracker.

DESIGN POSTURE (read before changing anything):
  This script does NOT write to Supabase. By deliberate decision, the actual
  database insert stays in Reagan's lane (run manually in the Supabase SQL
  editor against a reviewed file). This script does everything up to that point:
  parse, validate, auto-map, flag, backfill trainers from a local ledger, and
  emit a clean `ready_to_import` file you review before inserting.

  Promote to auto-write ONLY after: (1) IT scopes the credential question,
  (2) the 13 flat fields are validated against a real clients JSONB row, and
  (3) cross-batch dedup is checked against the LIVE db, not just the ledger.

WHAT IT DOES PER RUN (one-shot; schedule it, don't daemonize it):
  - Scans WATCH_DIR for *.csv (ignores its own output files and the archive)
  - For each source file:
      * read headers, auto-map to target fields
      * if first_name/last_name can't be mapped -> log warning, SKIP whole file
      * per-row validate (missing names / non-numeric sessions / dup)
      * backfill assigned_trainer from ledger when empty (flagged, never silent)
      * clean rows  -> ready_to_import_YYYY-MM-DD.csv
      * flagged rows -> flagged_for_review_YYYY-MM-DD.csv (with flag_reason)
      * move source file -> archive/
      * append a manifest line so split files stay traceable
  - Updates the local seen-names + last-trainer ledger

USAGE:
  python rectrac_import.py --watch-dir "C:\\path\\to\\dropfolder"
  python rectrac_import.py --watch-dir "..." --seed-ledger seed_clients.csv
  python rectrac_import.py --watch-dir "..." --dry-run

No third-party dependencies. Standard library only.
"""

import argparse
import csv
import datetime as dt
import json
import logging
import os
import shutil
import sys

# --------------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------------

# The 13 Supabase target fields, in output order.
TARGET_FIELDS = [
    "first_name",
    "last_name",
    "email",
    "phone",
    "date_of_birth",
    "emergency_contact",
    "emergency_phone",
    "pt_package",
    "package_sessions",
    "package_start",
    "package_expiry",
    "assigned_trainer",
    "transaction_type",
    "notes",
]

REQUIRED_FIELDS = ["first_name", "last_name"]

# Header alias map. Because Reagan controls the RecTrac export columns, the
# exact target-field names are listed first as the happy path. The rest are
# safety-net fallbacks so a slightly-off header still maps instead of silently
# dropping a column. All matching is case-insensitive and ignores spaces,
# underscores, hyphens (see _normalize_header).
HEADER_ALIASES = {
    "first_name":        ["first_name", "firstname", "first", "fname", "given name"],
    "last_name":         ["last_name", "lastname", "last", "lname", "surname", "family name"],
    "email":             ["email", "email_address", "e-mail"],
    "phone":             ["phone", "phone_number", "cell", "mobile", "telephone", "contact number"],
    "date_of_birth":     ["date_of_birth", "dob", "birthdate", "birth_date"],
    "emergency_contact": ["emergency_contact", "emergency_contact_name", "ec_name", "emergency name"],
    "emergency_phone":   ["emergency_phone", "emergency_contact_phone", "ec_phone", "emergency number"],
    "pt_package":        ["pt_package", "package", "package_type", "activity", "activity_code", "program"],
    "package_sessions":  ["package_sessions", "sessions", "session_count", "num_sessions", "qty"],
    "package_start":     ["package_start", "start_date", "package_start_date", "start", "begin_date"],
    "package_expiry":    ["package_expiry", "expiry", "expiration", "expiration_date", "end_date", "package_end"],
    "assigned_trainer":  ["assigned_trainer", "trainer", "instructor", "coach", "staff"],
    "transaction_type":  ["transaction_type", "transactiontype", "trans_type", "type"],
    "notes":             ["notes", "note", "comments", "remarks"],
}

# --------------------------------------------------------------------------
# PACKAGE TRANSLATION
# --------------------------------------------------------------------------
# RecTrac Pass Code (exact text) -> (locked package name, session count).
# Built from RecTrac_Training_Set_Up.csv (authoritative). SOLO PT packages
# only -- these route through the normal new/returning logic.
#
# Pairs and Group packages are deliberately NOT here. They are detected by
# keyword (see PAIRS_GROUP_KEYWORDS) and routed to a separate review lane,
# because a pairs/group purchase is a multi-person relationship the flat import
# cannot reconstruct (it collides with the Phase 2A/2C participant_ids model).
#
# An unknown Pass Code -- one not in this table and not pairs/group -- routes to
# flagged_for_review with reason unknown_pass_code. Never guess a translation.
PACKAGE_TRANSLATION = {
    "CMRC Personal Training Punch Pass - 1":  ("CMRC-PT-1", 1),
    "CMRC Personal Training Punch Pass - 3":  ("CMRC-PT-3", 3),
    "CMRC Personal Training Punch Pass - 5":  ("CMRC-PT-5", 5),
    "CMRC Personal Training Punch Pass - 10": ("CMRC-PT-10", 10),
    "CMRC Personal Training Punch Pass - 15": ("CMRC-PT-15", 15),
    "CMRC Personal Training Punch Pass - 20": ("CMRC-PT-20", 20),
    "Baca Personal Training Punch Pass - 01": ("Baca-PT-1", 1),
    "Baca Personal Training Punch Pass - 03": ("Baca-PT-3", 3),
    "Baca Personal Training Punch Pass - 05": ("Baca-PT-5", 5),
    "Baca Personal Training Punch Pass - 10": ("Baca-PT-10", 10),
    "Baca Personal Training Punch Pass - 15": ("Baca-PT-15", 15),
    "Baca Personal Training Punch Pass - 20": ("Baca-PT-20", 20),
    "Baca Personal Training Punch Pass - 1st Time": ("Baca-1stTime-3", 3),
}

# Any Pass Code containing one of these (case-insensitive) is a multi-person
# package -> review lane, untouched, never treated as a solo client.
PAIRS_GROUP_KEYWORDS = ("pairs", "group")


def _normalize_passcode(raw):
    """Collapse internal whitespace and trim. RecTrac is consistent but this
    guards against stray double-spaces around the dash."""
    return " ".join((raw or "").split())


def translate_package(raw_passcode):
    """Returns (kind, locked_name, sessions) where kind is one of:
      'solo'    -> translated solo PT package, route normally
      'review'  -> pairs/group, route to pairs_for_review lane
      'unknown' -> not recognized, route to flagged_for_review
    locked_name/sessions are None for review and unknown."""
    pc = _normalize_passcode(raw_passcode)
    if not pc:
        return ("unknown", None, None)
    low = pc.lower()
    if any(kw in low for kw in PAIRS_GROUP_KEYWORDS):
        return ("review", None, None)
    if pc in PACKAGE_TRANSLATION:
        name, sessions = PACKAGE_TRANSLATION[pc]
        return ("solo", name, sessions)
    return ("unknown", None, None)

LEDGER_FILENAME = ".import_ledger.json"   # lives in WATCH_DIR, hidden
ARCHIVE_SUBDIR = "archive"
MANIFEST_FILENAME = "import_manifest.log"

# Output files this script writes; never treat these as input.
OUTPUT_PREFIXES = ("ready_to_import_", "flagged_for_review_", "returning_clients_", "pairs_for_review_")


# --------------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------------

def _normalize_header(h):
    """Lowercase and strip spaces/underscores/hyphens for tolerant matching."""
    return "".join(ch for ch in h.lower() if ch.isalnum())


def _normalize_name_key(first, last):
    """Ledger/dedup key. Lowercased, trimmed. Collisions are possible by
    design (two real people, same name) -- that's why backfill is flagged,
    never silently trusted."""
    return f"{(first or '').strip().lower()}|{(last or '').strip().lower()}"


def build_header_map(csv_headers):
    """Map each target field to the actual CSV header that matches it.
    Returns (mapping, unmapped_targets). mapping is target_field -> csv_header."""
    norm_to_actual = {}
    for actual in csv_headers:
        norm_to_actual[_normalize_header(actual)] = actual

    mapping = {}
    for target, aliases in HEADER_ALIASES.items():
        for alias in aliases:
            norm_alias = _normalize_header(alias)
            if norm_alias in norm_to_actual:
                mapping[target] = norm_to_actual[norm_alias]
                break

    unmapped = [t for t in TARGET_FIELDS if t not in mapping]
    return mapping, unmapped


def is_numeric_sessions(value):
    """package_sessions must be a whole positive number. Empty is allowed
    (a client row can exist without a package); non-numeric is a flag."""
    v = (value or "").strip()
    if v == "":
        return True  # empty is acceptable, not a flag
    try:
        n = float(v)
        return n >= 0 and n == int(n)
    except ValueError:
        return False


def today_str():
    return dt.date.today().isoformat()


def normalize_date(value):
    """Normalize a date to ISO YYYY-MM-DD. Handles MM/DD/YYYY (RecTrac's
    format) and already-ISO values. Returns (iso_string, ok). On anything it
    can't parse confidently, returns the original value and ok=False so the
    row can be flagged rather than silently mangled."""
    v = (value or "").strip()
    if v == "":
        return ("", True)  # empty is fine; not all rows carry every date
    # Already ISO?
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y"):
        try:
            d = dt.datetime.strptime(v, fmt).date()
            return (d.isoformat(), True)
        except ValueError:
            continue
    return (v, False)


# --------------------------------------------------------------------------
# LEDGER
# --------------------------------------------------------------------------

def load_ledger(ledger_path):
    """Ledger schema: { "name_key": {"trainer": "...", "first_seen": "...",
    "last_seen": "..."} }. Trainer is the LAST KNOWN trainer from a CSV import
    or the seed. It is NOT authoritative over in-app reassignments -- that's
    why backfilled trainers are flagged for review on every run."""
    if not os.path.exists(ledger_path):
        return {}
    try:
        with open(ledger_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logging.warning("Ledger unreadable (%s). Starting empty ledger. "
                        "Existing file left in place, not overwritten.", e)
        return {}


def save_ledger(ledger_path, ledger):
    tmp = ledger_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ledger, f, indent=2)
    os.replace(tmp, ledger_path)  # atomic-ish; avoids a half-written ledger


def seed_ledger_from_csv(ledger_path, seed_csv):
    """One-time seed from a Supabase export Reagan runs himself (read stays in
    his lane). Expects columns first_name, last_name, assigned_trainer (or
    aliases). Merges into the existing ledger; does not clobber later data."""
    ledger = load_ledger(ledger_path)
    with open(seed_csv, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        mapping, unmapped = build_header_map(reader.fieldnames or [])
        if "first_name" in unmapped or "last_name" in unmapped:
            logging.error("Seed file missing first_name/last_name columns. "
                          "Found headers: %s. Seed aborted.", reader.fieldnames)
            return 0
        count = 0
        for row in reader:
            first = row.get(mapping.get("first_name", ""), "")
            last = row.get(mapping.get("last_name", ""), "")
            if not (first.strip() or last.strip()):
                continue
            trainer = ""
            if "assigned_trainer" in mapping:
                trainer = (row.get(mapping["assigned_trainer"], "") or "").strip()
            key = _normalize_name_key(first, last)
            entry = ledger.get(key, {})
            entry.setdefault("first_seen", "seed")
            entry["last_seen"] = "seed"
            # Only set trainer from seed if we actually have one and the ledger
            # doesn't already carry a non-empty value.
            if trainer and not entry.get("trainer"):
                entry["trainer"] = trainer
            ledger[key] = entry
            count += 1
    save_ledger(ledger_path, ledger)
    logging.info("Ledger seeded/merged from %s: %d names processed.", seed_csv, count)
    return count


# --------------------------------------------------------------------------
# CORE PIPELINE
# --------------------------------------------------------------------------

def process_file(src_path, watch_dir, ledger, dry_run=False):
    """Process one source CSV. Returns a dict summary for the manifest.
    Mutates `ledger` in memory (caller persists once at end of run)."""
    fname = os.path.basename(src_path)
    summary = {
        "file": fname,
        "skipped_file": False,
        "reason": "",
        "clean": 0,
        "flagged": 0,
        "returning": 0,
        "pairs": 0,
        "backfilled": 0,
        "unassigned": 0,
    }

    try:
        with open(src_path, "r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            headers = reader.fieldnames or []
            mapping, unmapped = build_header_map(headers)

            # Hard stop: required fields must map, else skip the WHOLE file.
            missing_required = [r for r in REQUIRED_FIELDS if r in unmapped]
            if missing_required:
                summary["skipped_file"] = True
                summary["reason"] = (
                    f"could not map required field(s) {missing_required} "
                    f"from headers {headers}"
                )
                logging.warning("SKIPPING FILE %s: %s", fname, summary["reason"])
                return summary

            logging.info("File %s mapped %d/%d target fields. Unmapped: %s",
                         fname, len(mapping), len(TARGET_FIELDS),
                         unmapped or "none")

            clean_rows = []
            flagged_rows = []
            returning_rows = []
            pairs_rows = []
            seen_this_batch = set()

            for line_no, raw in enumerate(reader, start=2):  # row 1 is header
                rec = {t: (raw.get(mapping[t], "") or "").strip()
                       if t in mapping else "" for t in TARGET_FIELDS}

                # ---- package translation FIRST ----
                # Determines whether this row is a solo PT package (route
                # normally), a pairs/group package (own review lane), or an
                # unrecognized Pass Code (flag). Done before name logic so
                # pairs/group rows never get treated as solo clients.
                raw_passcode = rec["pt_package"]
                kind, locked_name, sessions = translate_package(raw_passcode)

                if kind == "review":
                    # Pairs/Group: a multi-person package the flat import can't
                    # reconstruct. Route untouched to its own lane; Reagan links
                    # participants in-app via the pairs-to-confirm queue.
                    out = dict(rec)
                    out["raw_pass_code"] = raw_passcode
                    out["source_file"] = fname
                    out["source_row"] = line_no
                    pairs_rows.append(out)
                    summary["pairs"] += 1
                    continue

                if kind == "unknown":
                    out = dict(rec)
                    out["flag_reason"] = "unknown_pass_code"
                    out["raw_pass_code"] = raw_passcode
                    out["source_file"] = fname
                    out["source_row"] = line_no
                    flagged_rows.append(out)
                    summary["flagged"] += 1
                    continue

                # Solo PT package. Stamp locked name + derived session count.
                # The session count comes from the authoritative setup table,
                # NOT from a CSV column, so it can't be non-numeric here.
                rec["pt_package"] = locked_name
                if not rec["package_sessions"]:
                    rec["package_sessions"] = str(sessions)

                # ---- date normalization to ISO ----
                date_flags = []
                for dfield in ("date_of_birth", "package_start", "package_expiry"):
                    iso, ok = normalize_date(rec[dfield])
                    rec[dfield] = iso
                    if not ok:
                        date_flags.append(f"bad_date:{dfield}")

                # "Hard" flags mean the row is broken and a human must look at
                # it before anything happens.
                hard_flags = list(date_flags)

                # Rule 1: missing BOTH names
                if not rec["first_name"] and not rec["last_name"]:
                    hard_flags.append("missing_both_names")

                # Rule 2: non-numeric session count (defensive; should be set
                # from the table above, but a CSV-supplied value could be junk)
                if not is_numeric_sessions(rec["package_sessions"]):
                    hard_flags.append("non_numeric_sessions")

                # Rule 3: same name seen earlier in THIS file. With a daily
                # purchases report this is legitimate (someone buys two packages
                # in one day). NOT a hard flag -- routes as an additional-
                # purchase append candidate.
                key = _normalize_name_key(rec["first_name"], rec["last_name"])
                seen_earlier_in_batch = key != "|" and key in seen_this_batch
                seen_this_batch.add(key)

                # Rule 4: returning client. Two independent signals:
                #   - RecTrac says transaction_type == Renewal (authoritative)
                #   - the ledger has seen this name before (backstop)
                # Either makes it a package-append candidate, not a new insert.
                tx_type = rec["transaction_type"].strip().lower()
                is_renewal = tx_type == "renewal"
                is_known = key != "|" and key in ledger

                # ---- routing ----
                if hard_flags:
                    reasons = list(hard_flags)
                    if is_known or is_renewal:
                        reasons.append("also_matches_known_client")
                    out = dict(rec)
                    out["flag_reason"] = ";".join(reasons)
                    out["raw_pass_code"] = raw_passcode
                    out["source_file"] = fname
                    out["source_row"] = line_no
                    flagged_rows.append(out)
                    summary["flagged"] += 1
                    continue

                # Resolve trainer once -- both lanes backfill the same way.
                if rec["assigned_trainer"]:
                    trainer_source = "csv"
                else:
                    prior = ledger.get(key, {}).get("trainer", "")
                    if prior:
                        rec["assigned_trainer"] = prior
                        trainer_source = "ledger_backfill"
                        summary["backfilled"] += 1
                    else:
                        trainer_source = "unassigned"
                        summary["unassigned"] += 1

                if is_renewal or is_known or seen_earlier_in_batch:
                    # PACKAGE-APPEND candidate, not a new-client insert.
                    #   is_renewal           -> RecTrac flagged it a Renewal
                    #   is_known             -> name seen in a prior run / seed
                    #   seen_earlier_in_batch -> 2nd+ row for this name today
                    notes = []
                    if is_renewal:
                        notes.append("rectrac_renewal")
                    if is_known and not is_renewal:
                        notes.append("package_append_candidate")
                    if seen_earlier_in_batch:
                        notes.append("same_day_additional_purchase")
                    if not notes:
                        notes.append("package_append_candidate")
                    out = dict(rec)
                    out["trainer_source"] = trainer_source
                    out["match_note"] = ";".join(notes)
                    out["source_file"] = fname
                    out["source_row"] = line_no
                    returning_rows.append(out)
                    summary["returning"] += 1
                else:
                    # Net-new client. Safe to insert.
                    out = dict(rec)
                    out["trainer_source"] = trainer_source
                    out["source_file"] = fname
                    out["source_row"] = line_no
                    clean_rows.append(out)
                    summary["clean"] += 1

                # Update ledger. Only set trainer from a CSV-carried value.
                entry = ledger.get(key, {})
                entry.setdefault("first_seen", today_str())
                entry["last_seen"] = today_str()
                if trainer_source == "csv":
                    entry["trainer"] = rec["assigned_trainer"]
                else:
                    entry.setdefault("trainer", "")
                ledger[key] = entry

    except (OSError, csv.Error) as e:
        summary["skipped_file"] = True
        summary["reason"] = f"read error: {e}"
        logging.error("SKIPPING FILE %s: %s", fname, e)
        return summary

    if dry_run:
        logging.info("[dry-run] %s: %d new, %d returning, %d pairs, "
                     "%d flagged (no files written, no archive, no ledger "
                     "persist)", fname, summary["clean"], summary["returning"],
                     summary["pairs"], summary["flagged"])
        return summary

    # ---- write outputs (append within the same day) ----
    # Three lanes, deliberately separate:
    #   ready_to_import      -> net-new clients, INSERTS only
    #   returning_clients    -> known names, PACKAGE-APPEND candidates (not inserts)
    #   flagged_for_review   -> genuinely broken rows needing a human
    if clean_rows:
        _append_csv(
            os.path.join(watch_dir, f"ready_to_import_{today_str()}.csv"),
            clean_rows,
            TARGET_FIELDS + ["trainer_source", "source_file", "source_row"],
        )
    if returning_rows:
        _append_csv(
            os.path.join(watch_dir, f"returning_clients_{today_str()}.csv"),
            returning_rows,
            TARGET_FIELDS + ["trainer_source", "match_note", "source_file", "source_row"],
        )
    if flagged_rows:
        _append_csv(
            os.path.join(watch_dir, f"flagged_for_review_{today_str()}.csv"),
            flagged_rows,
            TARGET_FIELDS + ["flag_reason", "raw_pass_code", "source_file", "source_row"],
        )
    if pairs_rows:
        _append_csv(
            os.path.join(watch_dir, f"pairs_for_review_{today_str()}.csv"),
            pairs_rows,
            TARGET_FIELDS + ["raw_pass_code", "source_file", "source_row"],
        )

    # ---- archive source ----
    archive_dir = os.path.join(watch_dir, ARCHIVE_SUBDIR)
    os.makedirs(archive_dir, exist_ok=True)
    archived_name = f"{os.path.splitext(fname)[0]}__{today_str()}{os.path.splitext(fname)[1]}"
    shutil.move(src_path, os.path.join(archive_dir, archived_name))
    logging.info("Archived %s -> %s/%s", fname, ARCHIVE_SUBDIR, archived_name)

    return summary


def _append_csv(path, rows, fieldnames):
    """Append rows to a daily output file, writing a header only if new."""
    new_file = not os.path.exists(path)
    with open(path, "a", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        if new_file:
            writer.writeheader()
        writer.writerows(rows)


def write_manifest(watch_dir, summaries, dry_run=False):
    if dry_run:
        return
    path = os.path.join(watch_dir, MANIFEST_FILENAME)
    stamp = dt.datetime.now().isoformat(timespec="seconds")
    with open(path, "a", encoding="utf-8") as f:
        for s in summaries:
            if s["skipped_file"]:
                f.write(f"{stamp}\tFILE_SKIPPED\t{s['file']}\t{s['reason']}\n")
            else:
                f.write(
                    f"{stamp}\tPROCESSED\t{s['file']}\t"
                    f"new={s['clean']} returning={s['returning']} "
                    f"pairs={s['pairs']} flagged={s['flagged']} "
                    f"backfilled={s['backfilled']} unassigned={s['unassigned']}\n"
                )


# --------------------------------------------------------------------------
# ENTRYPOINT
# --------------------------------------------------------------------------

def find_source_csvs(watch_dir):
    out = []
    for name in os.listdir(watch_dir):
        if not name.lower().endswith(".csv"):
            continue
        if name.startswith(OUTPUT_PREFIXES):
            continue
        full = os.path.join(watch_dir, name)
        if os.path.isfile(full):
            out.append(full)
    return sorted(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description="RecTrac CSV import processor (no-write).")
    parser.add_argument("--watch-dir", required=True,
                        help="Folder Power Automate drops RecTrac CSVs into.")
    parser.add_argument("--seed-ledger", metavar="CSV",
                        help="One-time: seed the trainer ledger from a Supabase "
                             "export (first_name,last_name,assigned_trainer).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Parse and report only. No files written, no "
                             "archive, no ledger changes.")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    watch_dir = os.path.abspath(args.watch_dir)
    if not os.path.isdir(watch_dir):
        logging.error("watch-dir does not exist: %s", watch_dir)
        return 2

    ledger_path = os.path.join(watch_dir, LEDGER_FILENAME)

    if args.seed_ledger:
        if not os.path.isfile(args.seed_ledger):
            logging.error("seed file not found: %s", args.seed_ledger)
            return 2
        seed_ledger_from_csv(ledger_path, args.seed_ledger)
        # Seeding is its own action; don't also process in the same run.
        return 0

    sources = find_source_csvs(watch_dir)
    if not sources:
        logging.info("No source CSVs to process in %s", watch_dir)
        return 0

    ledger = load_ledger(ledger_path)
    summaries = []
    for src in sources:
        summaries.append(process_file(src, watch_dir, ledger, dry_run=args.dry_run))

    if not args.dry_run:
        save_ledger(ledger_path, ledger)
    write_manifest(watch_dir, summaries, dry_run=args.dry_run)

    total_clean = sum(s["clean"] for s in summaries)
    total_returning = sum(s["returning"] for s in summaries)
    total_pairs = sum(s["pairs"] for s in summaries)
    total_flagged = sum(s["flagged"] for s in summaries)
    skipped = sum(1 for s in summaries if s["skipped_file"])
    logging.info("Run complete. %d file(s): %d new client(s), %d returning, "
                 "%d pairs/group, %d flagged, %d file(s) skipped.",
                 len(summaries), total_clean, total_returning, total_pairs,
                 total_flagged, skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
