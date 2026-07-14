#!/usr/bin/env python3
"""
RLS IDENTITY-MODEL acceptance suite (Deploy 2: migrations 0004 + 0005).

WHY THIS EXISTS ALONGSIDE rls_staging_test.py
---------------------------------------------
rls_staging_test.py tests the Deploy 1 model, where `anon` legitimately has
SELECT/INSERT/UPDATE on the operational tables. Under that model, this is a PASS:

    PASS  anon can select clients

Reagan's call on 2026-07-13 was that client data must NOT be publicly viewable.
Under the model we are actually shipping, that same line is a CRITICAL FAILURE.
The old suite would happily certify a database that the whole internet can read.

So this suite inverts the anon assertions and adds the two seats that matter:
a signed-in trainer and a signed-in admin, each carrying a real JWT minted by
sign_in().

WHAT IT CHECKS
--------------
  1. anon (the public internet) can reach NOTHING except the sign-in roster.
  2. sign_in() mints a usable JWT, and the lockout still applies.
  3. A signed-in TRAINER can do the app's job but cannot delete, cannot read
     settings (the admin PIN hash), and cannot reset PINs.
  4. A signed-in ADMIN can delete and can read settings.
  5. A trainer cannot see another trainer's notifications.
  6. Both import pipelines still work on the service_role key.

USAGE (from repo root, after applying 0001-0002, then 0004-0005, to a STAGING
project or branch, and after putting the JWT secret in Vault):

  $env:SUPABASE_URL = "https://<staging-ref>.supabase.co"
  $env:SUPABASE_ANON_KEY = "<staging anon key>"
  $env:SUPABASE_SERVICE_ROLE_KEY = "<staging service_role key>"
  python scripts/staging/rls_identity_test.py

Exit 0 = all green. POINTS AT STAGING ONLY; refuses the production ref.
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

OPERATIONAL = ("clients", "leads", "wros", "classes", "trainers", "closures",
               "member_contacts", "admin_items", "referrals", "schedule_versions",
               "trainer_time_off", "notifications", "announcement_banners")

LOCKED = ("trainer_pins", "pin_attempts", "packages", "package_participants",
          "queue", "settings")


def check(label, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    (PASSED if ok else FAILED).append(label)
    print("%s  %s%s" % (tag, label, ("  [" + str(detail)[:160] + "]") if detail and not ok else ""))


def req(key, method, path, body=None, prefer=None, bearer=None):
    """(status, parsed_or_text). `key` is the apikey; `bearer` overrides the
    Authorization header, which is how we present a sign_in() token."""
    headers = {"apikey": key,
               "Authorization": "Bearer " + (bearer or key),
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
    except Exception as ex:  # noqa: BLE001
        return 0, str(ex)


def rpc(key, name, args, bearer=None):
    return req(key, "POST", "/rest/v1/rpc/" + name, body=args, bearer=bearer)


def blocked(code, out):
    """anon is denied twice: no GRANT (401/403) and no policy (200 + [])."""
    return code in (401, 403, 404) or (code == 200 and out == [])


def main():
    if not BASE or not ANON or not SERVICE:
        print("Set SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (staging values).")
        return 2
    if "<paste" in SERVICE or "<paste" in ANON:
        print("You pasted the placeholder, not the key. Get the real service_role key")
        print("from Dashboard > Project Settings > API and try again.")
        return 2
    if "ofezaezijafglyjmisgz" in BASE:
        print("REFUSING TO RUN: SUPABASE_URL is the PRODUCTION project. Point at staging.")
        return 2

    run_id = uuid.uuid4().hex[:8]
    print("== RLS identity-model verification (run %s) against %s ==\n" % (run_id, BASE))

    # ---- 1. anon is the public internet. It gets nothing. --------------------
    print("-- SEAT: anon (anyone with the public URL) --")
    for t in OPERATIONAL + LOCKED:
        code, out = req(ANON, "GET", "/rest/v1/%s?select=*&limit=1" % t)
        check("anon CANNOT read %s" % t, blocked(code, out), (code, out))

    code, out = req(ANON, "GET", "/rest/v1/trainer_directory?select=id,name,pin_set")
    roster_ok = code == 200 and isinstance(out, list)
    check("anon CAN read trainer_directory (login screen)", roster_ok, (code, out))

    code, out = req(ANON, "POST", "/rest/v1/clients",
                    body={"name": "RLSTEST anon-insert %s" % run_id},
                    prefer="return=representation")
    check("anon CANNOT insert clients", code not in (200, 201), (code, out))

    # ---- 2. bootstrap two seats with the service_role key --------------------
    print("\n-- BOOTSTRAP (service_role) --")
    tid, aid = str(uuid.uuid4()), str(uuid.uuid4())
    code, _ = req(SERVICE, "POST", "/rest/v1/trainers",
                  body=[{"id": tid, "name": "RLSTEST Trainer %s" % run_id, "role_tier": "trainer"},
                        {"id": aid, "name": "RLSTEST Admin %s" % run_id, "role_tier": "admin"}],
                  prefer="return=representation")
    check("service_role seeds trainer + admin", code in (200, 201), code)

    code, out = rpc(SERVICE, "set_trainer_pin", {"p_trainer_id": tid, "p_new": "1111"})
    check("service_role can bootstrap a PIN", code == 200 and out == "ok", (code, out))
    code, out = rpc(SERVICE, "set_trainer_pin", {"p_trainer_id": aid, "p_new": "2222"})
    check("service_role can bootstrap admin PIN", code == 200 and out == "ok", (code, out))

    # anon must NOT be able to reset a PIN and impersonate someone
    code, out = rpc(ANON, "set_trainer_pin", {"p_trainer_id": tid, "p_new": "9999"})
    check("anon CANNOT reset a PIN", not (code == 200 and out == "ok"), (code, out))

    # ---- 3. sign_in mints a token -------------------------------------------
    print("\n-- SIGN IN --")
    code, out = rpc(ANON, "sign_in", {"p_trainer_id": tid, "p_pin": "9999"})
    check("sign_in wrong PIN -> no token",
          code == 200 and out.get("status") == "wrong" and "token" not in out, (code, out))

    code, out = rpc(ANON, "sign_in", {"p_trainer_id": tid, "p_pin": "1111"})
    tok_t = out.get("token") if isinstance(out, dict) else None
    check("sign_in correct PIN -> token", code == 200 and bool(tok_t), (code, out))
    check("token is a 3-segment JWT", bool(tok_t) and len(tok_t.split(".")) == 3, tok_t)

    code, out = rpc(ANON, "sign_in", {"p_trainer_id": aid, "p_pin": "2222"})
    tok_a = out.get("token") if isinstance(out, dict) else None
    check("admin sign_in -> token", code == 200 and bool(tok_a), (code, out))
    check("admin token carries role_tier=admin",
          isinstance(out, dict) and out.get("trainer", {}).get("role_tier") == "admin", out)

    if not tok_t or not tok_a:
        print("\nCannot continue without tokens. Is the JWT secret in Vault?")
        print("  select vault.create_secret('<JWT secret>', 'app_jwt_secret');")
        return 1

    # ---- 4. signed-in TRAINER ------------------------------------------------
    print("\n-- SEAT: signed-in trainer --")
    code, out = req(ANON, "GET", "/rest/v1/clients?select=id&limit=1", bearer=tok_t)
    check("trainer CAN read clients", code == 200, (code, out))

    cid = str(uuid.uuid4())
    code, _ = req(ANON, "POST", "/rest/v1/clients",
                  body={"id": cid, "name": "RLSTEST client %s" % run_id},
                  prefer="return=representation", bearer=tok_t)
    check("trainer CAN insert client", code in (200, 201), code)

    code, _ = req(ANON, "PATCH", "/rest/v1/clients?id=eq." + cid,
                  body={"notes": "touched"}, prefer="return=representation", bearer=tok_t)
    check("trainer CAN update client", code in (200, 204), code)

    code, out = req(ANON, "DELETE", "/rest/v1/clients?id=eq." + cid,
                    prefer="return=representation", bearer=tok_t)
    check("trainer CANNOT delete client", not (code == 200 and out), (code, out))

    code, out = req(ANON, "GET", "/rest/v1/settings?select=*", bearer=tok_t)
    check("trainer CANNOT read settings (admin PIN hash)", blocked(code, out), (code, out))

    code, out = rpc(ANON, "set_trainer_pin", {"p_trainer_id": aid, "p_new": "0000"}, bearer=tok_t)
    check("trainer CANNOT reset another PIN", code == 200 and out == "forbidden", (code, out))

    # notifications are per-trainer
    req(SERVICE, "POST", "/rest/v1/notifications",
        body={"target_trainer_id": aid, "type": "RLSTEST %s" % run_id})
    code, out = req(ANON, "GET", "/rest/v1/notifications?select=*&type=eq.RLSTEST %s" % run_id,
                    bearer=tok_t)
    check("trainer CANNOT see another trainer's notifications",
          code == 200 and out == [], (code, out))

    # ---- 5. signed-in ADMIN --------------------------------------------------
    print("\n-- SEAT: signed-in admin --")
    code, out = req(ANON, "GET", "/rest/v1/settings?select=*", bearer=tok_a)
    check("admin CAN read settings", code == 200, (code, out))

    code, out = req(ANON, "DELETE", "/rest/v1/clients?id=eq." + cid,
                    prefer="return=representation", bearer=tok_a)
    check("admin CAN delete client", code == 200 and bool(out), (code, out))

    code, out = rpc(ANON, "set_trainer_pin", {"p_trainer_id": tid, "p_new": "3333"}, bearer=tok_a)
    check("admin CAN reset a PIN", code == 200 and out == "ok", (code, out))

    code, out = rpc(ANON, "sign_in", {"p_trainer_id": tid, "p_pin": "3333"}, bearer=tok_a)
    check("trainer can sign in with the new PIN",
          code == 200 and isinstance(out, dict) and out.get("status") == "ok", (code, out))

    # ---- 6. lockout still applies -------------------------------------------
    print("\n-- LOCKOUT --")
    last = None
    for _ in range(6):
        _, last = rpc(ANON, "sign_in", {"p_trainer_id": tid, "p_pin": "0000"})
    check("5+ failures -> locked",
          isinstance(last, dict) and last.get("status") == "locked", last)
    code, out = rpc(ANON, "sign_in", {"p_trainer_id": tid, "p_pin": "3333"})
    check("correct PIN while locked -> still locked",
          isinstance(out, dict) and out.get("status") == "locked", out)
    req(SERVICE, "DELETE", "/rest/v1/pin_attempts?scope=eq.trainer:" + tid)

    # ---- 7. pipelines still run on service_role -----------------------------
    print("\n-- PIPELINES (service_role, bypasses RLS) --")
    env = dict(os.environ)
    env["SUPABASE_URL"] = BASE
    env["SUPABASE_SERVICE_ROLE_KEY"] = SERVICE
    env.pop("SUPABASE_ANON_KEY", None)

    tmp = tempfile.mkdtemp(prefix="rlstest_")
    intake_dir = os.path.join(tmp, "intake")
    purch_dir = os.path.join(tmp, "purchases")
    shutil.copytree(os.path.join(FIXTURES, "intake_dropbox"), intake_dir)
    shutil.copytree(os.path.join(FIXTURES, "purchases_dropbox"), purch_dir)

    r = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "intake-import", "intake_import.py"),
                        "--watch-dir", intake_dir], env=env, capture_output=True, text=True)
    check("intake_import exits 0 under RLS", r.returncode == 0, (r.stdout + r.stderr)[-300:])

    code, out = req(SERVICE, "GET",
                    "/rest/v1/clients?select=id,from_queue_id&email=eq.rlstest.intake@example.com")
    check("intake fixture created client + linked lead",
          code == 200 and len(out) == 1 and out[0].get("from_queue_id"), (code, out))

    r = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "purchase-import", "purchase_import.py"),
                        "--watch-dir", purch_dir], env=env, capture_output=True, text=True)
    check("purchase_import exits 0 under RLS", r.returncode == 0, (r.stdout + r.stderr)[-300:])

    code, out = req(SERVICE, "GET",
                    "/rest/v1/clients?select=packages&email=eq.rlstest.intake@example.com")
    check("purchase appended CMRC-PT-5",
          code == 200 and len(out) == 1
          and any(p.get("type") == "CMRC-PT-5" for p in (out[0].get("packages") or [])), (code, out))

    # ---- summary -------------------------------------------------------------
    print("\n== %d passed, %d failed ==" % (len(PASSED), len(FAILED)))
    if FAILED:
        print("Failed checks:")
        for f in FAILED:
            print("  - " + f)
    else:
        print("Client data is not readable by the public internet.")
    print("\nTest rows are prefixed RLSTEST / rlstest.*@example.com.")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
