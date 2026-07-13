#!/usr/bin/env python3
"""
RLS + PIN hashing staging verification (item 3 of the post-v4.45 work order).

Runs the full acceptance suite against the STAGING Supabase project:
  1. Negative tests: the anon key cannot read the admin PIN, cannot touch
     trainer_pins / pin_attempts / packages / package_participants / queue,
     and cannot hard-delete operational rows.
  2. App-critical writes as anon: the storage-adapter verbs the app depends
     on (select / insert / update) still work on operational tables.
  3. PIN RPCs: bootstrap, verify, wrong-PIN, and the 5-failure lockout.
  4. Both import pipelines end to end with the SERVICE ROLE key, using the
     fixtures in scripts/staging/fixtures/ (copied to a temp dir; the
     importers archive their inputs).

USAGE (from the repo root, after applying migrations 0001-0003 in staging):
  set SUPABASE_URL=https://<staging-ref>.supabase.co
  set SUPABASE_ANON_KEY=<staging anon key>
  set SUPABASE_SERVICE_ROLE_KEY=<staging service role key>
  python scripts/staging/rls_staging_test.py

Exit code 0 = all green. Prints a PASS/FAIL line per check.
POINT THIS AT STAGING ONLY. It writes test rows (prefixed RLSTEST) and
overwrites the staging admin PIN.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
import uuid

BASE = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
ANON = os.environ.get("SUPABASE_ANON_KEY") or ""
SERVICE = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or ""

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

PASSED, FAILED = [], []


def check(label, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    (PASSED if ok else FAILED).append(label)
    print("%s  %s%s" % (tag, label, ("  [" + str(detail)[:160] + "]") if detail and not ok else ""))


def req(key, method, path, body=None, prefer=None):
    """Returns (status_code, parsed_or_text). Never raises."""
    headers = {"apikey": key, "Authorization": "Bearer " + key,
               "Content-Type": "application/json"}
    if prefer:
        headers["Prefer"] = prefer
    data = json.dumps(body).encode("utf-8") if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            try:
                return resp.status, (json.loads(raw) if raw else None)
            except ValueError:
                return resp.status, raw
    except urllib.error.HTTPError as ex:
        return ex.code, ex.read().decode("utf-8", "replace")
    except Exception as ex:  # noqa: BLE001 - report, don't crash the suite
        return -1, str(ex)


def rpc(key, name, args):
    return req(key, "POST", "/rest/v1/rpc/" + name, body=args)


def main():
    if not BASE or not ANON or not SERVICE:
        print("Set SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (staging values).")
        return 2
    if "ofezaezijafglyjmisgz" in BASE:
        print("REFUSING TO RUN: SUPABASE_URL is the PRODUCTION project. Point at staging.")
        return 2

    run_id = uuid.uuid4().hex[:8]
    print("== RLS staging verification (run %s) against %s ==\n" % (run_id, BASE))

    # ---- 0. connectivity ----------------------------------------------------
    code, _ = req(ANON, "GET", "/rest/v1/clients?select=id&limit=1")
    check("staging reachable with anon key", code == 200, code)

    # ---- 1. negative tests (anon) -------------------------------------------
    code, out = req(ANON, "GET", "/rest/v1/settings?select=key,value&key=eq.admin_pin")
    check("anon cannot read admin_pin settings row", code == 200 and out == [], (code, out))

    code, out = req(ANON, "GET", "/rest/v1/trainer_pins?select=*")
    check("anon cannot read trainer_pins", code != 200 or out == [], (code, out))

    code, out = req(ANON, "GET", "/rest/v1/pin_attempts?select=*")
    check("anon cannot read pin_attempts", code != 200 or out == [], (code, out))

    for t in ("packages", "package_participants", "queue"):
        code, out = req(ANON, "GET", "/rest/v1/%s?select=*&limit=1" % t)
        check("anon cannot read %s" % t, code != 200 or out == [], (code, out))

    # seed a client with the service key, then prove anon cannot hard-delete it
    cid = str(uuid.uuid4())
    code, _ = req(SERVICE, "POST", "/rest/v1/clients",
                  body={"id": cid, "name": "RLSTEST delete-guard %s" % run_id},
                  prefer="return=representation")
    check("service key can insert client", code in (200, 201), code)
    code, out = req(ANON, "DELETE", "/rest/v1/clients?id=eq." + cid, prefer="return=representation")
    deleted = code == 200 and isinstance(out, list) and len(out) > 0
    check("anon cannot hard-delete clients", not deleted, (code, out))
    code, out = req(SERVICE, "GET", "/rest/v1/clients?select=id&id=eq." + cid)
    check("delete-guard row still present", code == 200 and len(out) == 1, (code, out))

    # ---- 2. app-critical writes as anon --------------------------------------
    lid = str(uuid.uuid4())
    code, _ = req(ANON, "POST", "/rest/v1/leads",
                  body={"id": lid, "name": "RLSTEST lead %s" % run_id,
                        "source": "walkin", "status": "waiting"},
                  prefer="return=representation")
    check("anon can insert lead (app write path)", code in (200, 201), code)
    code, _ = req(ANON, "PATCH", "/rest/v1/leads?id=eq." + lid,
                  body={"status": "contacted"}, prefer="return=representation")
    check("anon can update lead", code in (200, 204), code)
    code, _ = req(ANON, "PATCH", "/rest/v1/clients?id=eq." + cid,
                  body={"name": "RLSTEST delete-guard %s updated" % run_id},
                  prefer="return=representation")
    check("anon can update client", code in (200, 204), code)
    for t in ("classes", "wros", "trainer_time_off", "notifications",
              "closures", "member_contacts", "admin_items", "referrals",
              "schedule_versions", "trainers", "announcement_banners"):
        code, _ = req(ANON, "GET", "/rest/v1/%s?select=*&limit=1" % t)
        check("anon can select %s" % t, code == 200, code)

    # ---- 3. PIN RPCs ----------------------------------------------------------
    # Admin PIN: force a known state with the service key path (set may need
    # bootstrap OR the current staging PIN; try bootstrap first).
    code, out = rpc(ANON, "set_admin_pin", {"p_current": None, "p_new": "4321"})
    if code == 200 and out == "wrong":
        print("  (admin PIN already set in staging; set the seed PIN by re-running")
        print("   migration 0002 on a fresh staging DB, or pass the current PIN)")
    check("set_admin_pin reachable", code == 200, (code, out))
    admin_ready = code == 200 and out == "ok"

    if admin_ready:
        code, out = rpc(ANON, "verify_admin_pin", {"p_pin": "4321"})
        check("verify_admin_pin correct -> ok", code == 200 and out == "ok", (code, out))
        code, out = rpc(ANON, "verify_admin_pin", {"p_pin": "0000"})
        check("verify_admin_pin wrong -> wrong", code == 200 and out == "wrong", (code, out))
        last = None
        for _ in range(5):
            _, last = rpc(ANON, "verify_admin_pin", {"p_pin": "0000"})
        check("5 failures -> locked", last == "locked", last)
        code, out = rpc(ANON, "verify_admin_pin", {"p_pin": "4321"})
        check("correct PIN while locked -> still locked", code == 200 and out == "locked", (code, out))
        # clear the lock server-side so the suite is re-runnable
        code, _ = req(SERVICE, "DELETE", "/rest/v1/pin_attempts?scope=eq.admin")
        check("lock cleared for re-run (service key)", code in (200, 204), code)

    # Trainer PIN: seed a trainer, set, verify.
    tid = str(uuid.uuid4())
    code, _ = req(SERVICE, "POST", "/rest/v1/trainers",
                  body={"id": tid, "name": "RLSTEST Trainer %s" % run_id},
                  prefer="return=representation")
    check("seed trainer (service key)", code in (200, 201), code)
    code, out = rpc(ANON, "set_trainer_pin", {"p_trainer_id": tid, "p_new": "1111"})
    check("set_trainer_pin -> ok", code == 200 and out == "ok", (code, out))
    code, out = req(ANON, "GET", "/rest/v1/trainers?select=pin_set&id=eq." + tid)
    check("trainers.pin_set flipped true", code == 200 and out and out[0].get("pin_set") is True, (code, out))
    code, out = rpc(ANON, "verify_trainer_pin", {"p_trainer_id": tid, "p_pin": "1111"})
    check("verify_trainer_pin correct -> ok", code == 200 and out == "ok", (code, out))
    code, out = rpc(ANON, "verify_trainer_pin", {"p_trainer_id": tid, "p_pin": "9999"})
    check("verify_trainer_pin wrong -> wrong", code == 200 and out == "wrong", (code, out))

    # ---- 4. both pipelines end to end (service key) --------------------------
    env = dict(os.environ)
    env["SUPABASE_URL"] = BASE
    env["SUPABASE_SERVICE_ROLE_KEY"] = SERVICE
    env.pop("SUPABASE_ANON_KEY", None)  # prove the service key alone carries it

    tmp = tempfile.mkdtemp(prefix="rlstest_")
    intake_dir = os.path.join(tmp, "intake")
    purch_dir = os.path.join(tmp, "purchases")
    shutil.copytree(os.path.join(FIXTURES, "intake_dropbox"), intake_dir)
    shutil.copytree(os.path.join(FIXTURES, "purchases_dropbox"), purch_dir)

    r = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "intake-import", "intake_import.py"),
                        "--watch-dir", intake_dir], env=env, capture_output=True, text=True)
    check("intake_import exits 0 under RLS", r.returncode == 0, (r.stdout + r.stderr)[-300:])

    code, out = req(SERVICE, "GET",
                    "/rest/v1/clients?select=id,name,from_queue_id&email=eq.rlstest.intake@example.com")
    intake_ok = code == 200 and len(out) == 1 and out[0].get("from_queue_id")
    check("intake fixture created client + linked lead", bool(intake_ok), (code, out))
    if intake_ok:
        code, out = req(SERVICE, "GET",
                        "/rest/v1/leads?select=id,status,source&id=eq." + out[0]["from_queue_id"])
        check("intake lead is waiting/ms_forms", code == 200 and len(out) == 1
              and out[0]["status"] == "waiting" and out[0]["source"] == "ms_forms", (code, out))

    r = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "purchase-import", "purchase_import.py"),
                        "--watch-dir", purch_dir], env=env, capture_output=True, text=True)
    check("purchase_import exits 0 under RLS", r.returncode == 0, (r.stdout + r.stderr)[-300:])

    code, out = req(SERVICE, "GET",
                    "/rest/v1/clients?select=id,packages&email=eq.rlstest.intake@example.com")
    pkg_ok = (code == 200 and len(out) == 1
              and any(p.get("type") == "CMRC-PT-5" for p in (out[0].get("packages") or [])))
    check("purchase appended CMRC-PT-5 to the intake client", pkg_ok, (code, out))

    code, out = req(SERVICE, "GET",
                    "/rest/v1/clients?select=id,packages,location&email=eq.rlstest.purchase@example.com")
    new_ok = (code == 200 and len(out) == 1 and out[0].get("location") == "Baca"
              and any(p.get("type") == "Baca-PT-10" for p in (out[0].get("packages") or [])))
    check("purchase created new Baca client with package", new_ok, (code, out))

    # ---- summary --------------------------------------------------------------
    print("\n== %d passed, %d failed ==" % (len(PASSED), len(FAILED)))
    if FAILED:
        print("Failed checks:")
        for f in FAILED:
            print("  - " + f)
    print("\nTest rows are prefixed RLSTEST / rlstest.*@example.com - wipe staging")
    print("or ignore them; nothing here touches production.")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
