#!/usr/bin/env python3
"""
RecTrac PT-package purchase importer for the Round Rock Fitness Tracker.

Consumes the "PARD Training Packages Report" CSV (one row per purchase) and
attaches each purchase as a package on the matching client's profile in
Supabase. Built to run manually day one (export the report, drop the CSV in
the watch dir, run) and to be scheduled / Power-Automate-fed later, exactly
like the intake importer.

Expected CSV columns (from the live report):
  first_name, last_name, email, phone, date_of_birth,
  pt_package, package_start, package_expiry, transaction_type

DESIGN POSTURE:
  WRITES to Supabase via REST with the key in SUPABASE_ANON_KEY (RLS disabled,
  so the key authorizes the write). --dry-run performs ZERO writes and reports
  the plan. Idempotent: a package is keyed by (type, purchaseDate) per client,
  so re-running the same report never double-adds a package (the YTD report
  re-lists everything each run).

PER ROW:
  - Map pt_package -> canonical type (exact map + pattern fallback; handles
    Baca zero-padding "03" and the "1st Time" intro). Unmappable -> review.
  - Match a client by email, else phone (exact, unique).
  - Matched  -> append the package to client.packages if not already present.
  - No match -> CREATE the client from the row (name/email/phone/dob/location)
    carrying the package. (Backfill lands buyers who never did intake.)
  - Missing name / no email+phone / unknown package -> review CSV, no write.
  Pairs note: each partner is its own report row, so each becomes its own
  client+package; the app's Pairs-to-Confirm flow links them later.

USAGE:
  python purchase_import.py --watch-dir "C:\\...\\purchases_dropbox" --dry-run
  python purchase_import.py --watch-dir "C:\\...\\purchases_dropbox"

ENV:
  SUPABASE_URL       (default: the project URL below)
  SUPABASE_ANON_KEY  (required)

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

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Mirror of the app's PT_PACKAGES_BY_FACILITY (RoundRock_Fitness_Tracker.html),
# keyed by canonical type. Keep in sync if the app catalog changes. Includes the
# v4.45 additions CMRC-Pairs-8 / CMRC-Pairs-12.
PACKAGE_CATALOG = {
    "CMRC-Consult":  {"id": "cmrc-consult",  "location": "CMRC", "sessions": 0,  "price": 0,   "is_pairs": False, "is_consult": True,  "is_intro": False, "validDays": None},
    "CMRC-PT-1":     {"id": "cmrc-pt-1",     "location": "CMRC", "sessions": 1,  "price": 38,  "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-PT-3":     {"id": "cmrc-pt-3",     "location": "CMRC", "sessions": 3,  "price": 105, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-PT-5":     {"id": "cmrc-pt-5",     "location": "CMRC", "sessions": 5,  "price": 175, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-PT-10":    {"id": "cmrc-pt-10",    "location": "CMRC", "sessions": 10, "price": 330, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-PT-15":    {"id": "cmrc-pt-15",    "location": "CMRC", "sessions": 15, "price": 495, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-PT-20":    {"id": "cmrc-pt-20",    "location": "CMRC", "sessions": 20, "price": 630, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-Pairs-4":  {"id": "cmrc-pairs-4",  "location": "CMRC", "sessions": 4,  "price": 60,  "is_pairs": True,  "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-Pairs-8":  {"id": "cmrc-pairs-8",  "location": "CMRC", "sessions": 8,  "price": 105, "is_pairs": True,  "is_consult": False, "is_intro": False, "validDays": 365},
    "CMRC-Pairs-12": {"id": "cmrc-pairs-12", "location": "CMRC", "sessions": 12, "price": 145, "is_pairs": True,  "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-Consult":    {"id": "baca-consult",    "location": "Baca", "sessions": 0,  "price": 0,   "is_pairs": False, "is_consult": True,  "is_intro": False, "validDays": None},
    "Baca-1stTime-3":  {"id": "baca-1sttime-3",  "location": "Baca", "sessions": 3,  "price": 40,  "is_pairs": False, "is_consult": False, "is_intro": True,  "validDays": 365},
    "Baca-PT-3":       {"id": "baca-pt-3",       "location": "Baca", "sessions": 3,  "price": 75,  "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-PT-5":       {"id": "baca-pt-5",       "location": "Baca", "sessions": 5,  "price": 115, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-PT-10":      {"id": "baca-pt-10",      "location": "Baca", "sessions": 10, "price": 225, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-PT-15":      {"id": "baca-pt-15",      "location": "Baca", "sessions": 15, "price": 315, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-PT-20":      {"id": "baca-pt-20",      "location": "Baca", "sessions": 20, "price": 400, "is_pairs": False, "is_consult": False, "is_intro": False, "validDays": 365},
    "Baca-Pairs-4":    {"id": "baca-pairs-4",    "location": "Baca", "sessions": 4,  "price": 50,  "is_pairs": True,  "is_consult": False, "is_intro": False, "validDays": 30},
    "Baca-Pairs-8":    {"id": "baca-pairs-8",    "location": "Baca", "sessions": 8,  "price": 90,  "is_pairs": True,  "is_consult": False, "is_intro": False, "validDays": 60},
}

# Exact RecTrac product name -> canonical type (observed in the live reports).
# The pattern fallback in map_package_type handles anything not listed here.
PRODUCT_TYPE_MAP = {
    "CMRC Personal Training Punch Pass - 1":  "CMRC-PT-1",
    "CMRC Personal Training Punch Pass - 3":  "CMRC-PT-3",
    "CMRC Personal Training Punch Pass - 5":  "CMRC-PT-5",
    "CMRC Personal Training Punch Pass - 10": "CMRC-PT-10",
    "CMRC Personal Training Punch Pass - 15": "CMRC-PT-15",
    "CMRC Personal Training Punch Pass - 20": "CMRC-PT-20",
    "CMRC Pairs Training Punch Pass - 4":  "CMRC-Pairs-4",
    "CMRC Pairs Training Punch Pass - 8":  "CMRC-Pairs-8",
    "CMRC Pairs Training Punch Pass - 12": "CMRC-Pairs-12",
    "Baca Personal Training Punch Pass - 1st Time": "Baca-1stTime-3",
    "Baca Personal Training Punch Pass - 03": "Baca-PT-3",
    "Baca Personal Training Punch Pass - 05": "Baca-PT-5",
    "Baca Personal Training Punch Pass - 10": "Baca-PT-10",
    "Baca Personal Training Punch Pass - 15": "Baca-PT-15",
    "Baca Personal Training Punch Pass - 20": "Baca-PT-20",
    "Baca Pairs Training Punch Pass - 4": "Baca-Pairs-4",
    "Baca Pairs Training Punch Pass - 8": "Baca-Pairs-8",
}

log = logging.getLogger("purchase_import")


def digits(s):
    return re.sub(r"\D", "", s or "")


def to_iso_date(v):
    if not v or not isinstance(v, str):
        return None
    v = v.strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y",
                "%m/%d/%Y %H:%M:%S", "%m/%d/%Y %I:%M:%S %p"):
        try:
            return dt.datetime.strptime(v, fmt).date().isoformat()
        except ValueError:
            continue
    try:
        return dt.datetime.fromisoformat(v.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        return None


def days_between(a_iso, b_iso):
    try:
        a = dt.date.fromisoformat(a_iso)
        b = dt.date.fromisoformat(b_iso)
        return (b - a).days
    except (ValueError, TypeError):
        return None


def map_package_type(name):
    """RecTrac product name -> canonical type, or None if unmappable."""
    s = re.sub(r"\s+", " ", (name or "").strip())
    if s in PRODUCT_TYPE_MAP:
        return PRODUCT_TYPE_MAP[s]
    m = re.search(r"\b(CMRC|Baca)\b.*?(Personal|Pairs)\s+Training.*?Punch Pass\s*-\s*(1st Time|\d+)", s, re.I)
    if not m:
        return None
    fac = "CMRC" if m.group(1).upper() == "CMRC" else "Baca"
    kind = "Pairs" if m.group(2).lower() == "pairs" else "PT"
    size = m.group(3).strip().lower()
    if size == "1st time":
        cand = "Baca-1stTime-3"
    else:
        cand = "%s-%s-%d" % (fac, kind, int(size))
    return cand if cand in PACKAGE_CATALOG else None


def _now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _get(base_url, key, path):
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
                "/rest/v1/clients?select=id,name,email,phone,packages&deleted_at=is.null")


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


def _http_err(ex):
    try:
        return "%s %s" % (ex.code, ex.read().decode("utf-8", "replace")[:300])
    except Exception:
        return str(ex)


def build_package(ptype, purchase_date, expiry_date, source, client_id):
    meta = PACKAGE_CATALOG[ptype]
    valid = days_between(purchase_date, expiry_date)
    if valid is None or valid <= 0:
        valid = meta["validDays"]
    pkg = {
        "id": str(uuid.uuid4()),
        "type": ptype,
        "template_id": meta["id"],
        "location": meta["location"],
        "sessions": meta["sessions"],
        "price": meta["price"],
        "amountPaid": meta["price"],   # report CSV has no paid column; catalog price
        "purchaseDate": purchase_date,
        "paymentType": None,
        "source": source,
        "is_pairs": meta["is_pairs"],
        "is_consult": meta["is_consult"],
        "is_intro": meta["is_intro"],
        "validDays": valid,
        "participant_ids": [client_id],
        "package_size": 2 if meta["is_pairs"] else 1,
        "primary_holder_id": client_id,
        "participants_at_creation": 1,
    }
    return pkg


def has_package(packages, ptype, purchase_date):
    """Idempotency key: same canonical type on the same purchase date."""
    for p in (packages or []):
        if p.get("type") == ptype and p.get("purchaseDate") == purchase_date:
            return True
    return False


def parse_row(row):
    """Normalize one CSV row -> (data dict, reason). data is None when invalid."""
    def g(*names):
        for n in names:
            if n in row and row[n] is not None and str(row[n]).strip() != "":
                return str(row[n]).strip()
        return ""
    first = g("first_name", "First Name")
    last = g("last_name", "Last Name")
    name = (first + " " + last).strip()
    email = g("email", "Email")
    phone = g("phone", "Phone")
    raw_pkg = g("pt_package", "Pass Code", "package")
    if not name:
        return None, "missing name"
    if not (email and EMAIL_RE.match(email)) and len(digits(phone)) < 10:
        return None, "no valid email or 10-digit phone"
    ptype = map_package_type(raw_pkg)
    if not ptype:
        return None, "unmapped package %r" % raw_pkg
    start = to_iso_date(g("package_start", "Tran Date", "package_purchase"))
    if not start:
        return None, "unparseable package_start"
    expiry = to_iso_date(g("package_expiry", "Exp Date"))
    tran = g("transaction_type", "Tran Type").lower()
    source = "rectrac_reup" if "renew" in tran else "rectrac_import"
    dob = to_iso_date(g("date_of_birth", "Birthday", "dob"))
    return {
        "name": name, "email": email or None, "phone": phone or None,
        "dob": dob, "type": ptype, "start": start, "expiry": expiry,
        "source": source, "location": PACKAGE_CATALOG[ptype]["location"],
    }, "ok"


def match_client(data, clients):
    email = (data.get("email") or "").strip().lower()
    phone = digits(data.get("phone"))
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
    return None, "no match"


def process(watch_dir, base_url, key, dry_run=False):
    today = dt.date.today().isoformat()
    archive = os.path.join(watch_dir, "archive")
    review = os.path.join(watch_dir, "review")
    review_csv = os.path.join(watch_dir, "review_%s.csv" % today)
    manifest = os.path.join(watch_dir, "manifest.log")

    files = sorted(
        f for f in os.listdir(watch_dir)
        if f.lower().endswith(".csv") and os.path.isfile(os.path.join(watch_dir, f))
        and not f.startswith("review_")
    )
    if not files:
        log.info("nothing to process")
        return 0

    clients = fetch_clients(base_url, key)
    # Working copy of each client's package array, so multiple rows for one
    # person in a single run accumulate correctly.
    pkgs = {c["id"]: list(c.get("packages") or []) for c in clients}
    log.info("matching against %d active clients%s",
             len(clients), " (DRY RUN - no writes)" if dry_run else "")
    if not dry_run:
        os.makedirs(archive, exist_ok=True)
        os.makedirs(review, exist_ok=True)

    added = created = skipped = flagged = 0
    review_rows = []
    for fname in files:
        src = os.path.join(watch_dir, fname)
        try:
            with open(src, encoding="utf-8-sig", newline="") as fh:
                rows = list(csv.DictReader(fh))
        except (ValueError, OSError) as ex:
            log.warning("%s: unreadable CSV (%s) -> review", fname, ex)
            flagged += 1
            review_rows.append([fname, "", "", "", "unreadable CSV: %s" % ex])
            continue

        file_ok = True
        for i, row in enumerate(rows, start=2):  # row 1 is the header
            data, reason = parse_row(row)
            tag = "%s:%d" % (fname, i)
            if data is None:
                flagged += 1
                file_ok = False
                review_rows.append([fname, row.get("first_name", ""), row.get("email", ""),
                                    row.get("phone", ""), reason])
                log.info("%s -> review (%s)", tag, reason)
                continue

            client, mreason = match_client(data, clients)
            if client and mreason.startswith("AMBIGUOUS"):
                flagged += 1
                file_ok = False
                review_rows.append([fname, data["name"], data.get("email") or "",
                                    data.get("phone") or "", mreason])
                log.info("%s -> review (%s)", tag, mreason)
                continue

            if client:
                cid = client["id"]
                if has_package(pkgs.get(cid), data["type"], data["start"]):
                    skipped += 1
                    log.info("%s -> skip, %s already has %s on %s",
                             tag, client.get("name"), data["type"], data["start"])
                    continue
                pkg = build_package(data["type"], data["start"], data["expiry"],
                                    data["source"], cid)
                new_pkgs = list(pkgs.get(cid) or []) + [pkg]
                if dry_run:
                    log.info("%s -> would ADD %s to %s (matched %s)",
                             tag, data["type"], client.get("name"), mreason)
                else:
                    try:
                        _write(base_url, key, "/rest/v1/clients?id=eq." + cid,
                               {"packages": new_pkgs, "last_package_added_at": _now(),
                                "updated_at": _now()}, "PATCH")
                    except urllib.error.HTTPError as ex:
                        flagged += 1
                        file_ok = False
                        log.error("%s: PATCH FAILED (%s)", tag, _http_err(ex))
                        review_rows.append([fname, data["name"], data.get("email") or "",
                                            data.get("phone") or "", "PATCH error: %s" % _http_err(ex)])
                        continue
                    log.info("%s -> ADDED %s to %s", tag, data["type"], client.get("name"))
                pkgs[cid] = new_pkgs
                added += 1
            else:
                # No client -> create from the purchase row, carrying the package.
                cid = str(uuid.uuid4())
                pkg = build_package(data["type"], data["start"], data["expiry"],
                                    data["source"], cid)
                if dry_run:
                    log.info("%s -> would CREATE client %r (%s / %s) with %s",
                             tag, data["name"], data.get("email") or "-",
                             data.get("phone") or "-", data["type"])
                else:
                    row_obj = {
                        "id": cid, "name": data["name"],
                        "email": data.get("email"), "phone": data.get("phone"),
                        "date_purchased": data["start"], "location": data["location"],
                        "is_active": True, "created_by": "RecTrac import",
                        "created_at": _now(), "updated_at": _now(),
                        "last_package_added_at": _now(), "packages": [pkg],
                    }
                    try:
                        _write(base_url, key, "/rest/v1/clients", row_obj, "POST")
                    except urllib.error.HTTPError as ex:
                        flagged += 1
                        file_ok = False
                        log.error("%s: POST FAILED (%s)", tag, _http_err(ex))
                        review_rows.append([fname, data["name"], data.get("email") or "",
                                            data.get("phone") or "", "POST error: %s" % _http_err(ex)])
                        continue
                    log.info("%s -> CREATED %s id=%s with %s", tag, data["name"], cid, data["type"])
                # Make the new client visible to later rows in this same run.
                clients.append({"id": cid, "name": data["name"], "email": data.get("email"),
                                "phone": data.get("phone"), "packages": [pkg]})
                pkgs[cid] = [pkg]
                created += 1

        if not dry_run:
            dest = archive if file_ok else review
            shutil.move(src, os.path.join(dest, fname))
            with open(manifest, "a", encoding="utf-8") as fh:
                fh.write("%s\t%s\t%s\n" % (today, fname, "archived" if file_ok else "review"))

    if review_rows and not dry_run:
        new = not os.path.exists(review_csv)
        with open(review_csv, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["file", "name", "email", "phone", "reason"])
            w.writerows(review_rows)

    log.info("done: %d packages added, %d clients created, %d skipped (dup), %d for review%s",
             added, created, skipped, flagged,
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
