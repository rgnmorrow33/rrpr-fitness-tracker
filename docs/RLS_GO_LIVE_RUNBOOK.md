# RLS + PIN Hashing: Staging Test and Go-Live Runbook

Item 3 of the post-v4.45 work order. Everything below is staged and NOTHING
has touched production. Production flip happens after Hawaii, on a day Reagan
can watch it, with Selisa available for iPad verification.

## What shipped in this pass (all staged)

| Piece | Where | State |
|---|---|---|
| PIN hashing migration | `migrations/0002_pin_hashing.sql` | Written, not applied |
| RLS policy set | `migrations/0003_rls_policies.sql` | Written, not applied |
| Emergency rollback | `sql/rls_emergency_rollback.sql` | Written, for go-live day pocket |
| Pipeline dual-key | `intake-import/intake_import.py`, `purchase-import/purchase_import.py` | Live-safe: identical behavior until `SUPABASE_SERVICE_ROLE_KEY` is set |
| App PIN changes | `staging/RoundRock_Fitness_Tracker.staging.html` | Staging copy; prod file untouched |
| Acceptance suite | `scripts/staging/rls_staging_test.py` + fixtures | Ready to run |

## What this pass does and does not fix (for the IT self-assessment)

Fixes: PINs hashed (bcrypt) and verified server-side with a 5-attempt
lockout, PINs and admin PIN unreadable/unwritable via the anon key, both
pipelines moved off the anon key, three unused tables (packages,
package_participants, queue) closed to anon, hard deletes closed except
banners, and RLS scaffolding on all 17 tables.

Does not fix: the anon key is committed in a public app by design, so for
operational tables (clients, leads, wros...) anyone with the key has the same
read/write the app has. That requires real per-user auth - scoped as the APC
gate, not this pass. If IT expected more, that is a conversation to have
before go-live.

## Phase 1 - Staging test (before Hawaii, ~1 hour)

1. Create a staging Supabase project (supabase.com > New project, any region,
   free tier fine). ~5 minutes to provision.
2. SQL editor: paste and run, in order:
   `migrations/0001_baseline.sql`, `migrations/0002_pin_hashing.sql`,
   `migrations/0003_rls_policies.sql`.
3. Grab from Project Settings > API: the URL, the `anon` key, and the
   `service_role` key.
4. From the repo root:

   ```
   set SUPABASE_URL=https://<staging-ref>.supabase.co
   set SUPABASE_ANON_KEY=<staging anon>
   set SUPABASE_SERVICE_ROLE_KEY=<staging service role>
   python scripts\staging\rls_staging_test.py
   ```

   Everything should PASS. The suite refuses to run against the prod URL.
5. App smoke: paste the staging URL and anon key into the two placeholders at
   the top of `staging/RoundRock_Fitness_Tracker.staging.html`, open it
   locally (`node scripts/serve-local.js` or just the file), then:
   - Manage Team: set the Front Desk PIN (current blank on first setup).
   - Add a team member, set their PIN in the Edit modal.
   - Sign out, sign back in with that PIN. Wrong PIN 5x -> lockout toast.
   - Log a session, add a lead, check the WRO board (anon writes under RLS).
6. Do NOT commit the staging keys. The placeholders stay placeholders in git.

## Phase 2 - GO-LIVE (SUPERSEDED - use this, not the older list below)

Rewritten 2026-07-14. The original sequence ran 0002 then 0003. **0003 is retired**
(every policy in it is `anon USING (true)`, which leaves `clients` world-readable).
The live sequence is 0002 -> 0004 -> 0005.

Everything below is verified: three-seat browser test against a Supabase branch,
plus the SQL acceptance suite. Nothing has touched production.

### Before you start

- Pick a LOW-TRAFFIC window. Sign-in is broken for about 60-90 seconds between
  step 3 and step 5. On a Tuesday mid-morning, the team is on the floor.
- Selisa available to hard-reload the iPads.
- `sql/rls_emergency_rollback.sql` open in a second SQL editor tab.
- `git status` clean.

### The sequence. Order is not optional.

**1. Put the PRODUCTION JWT secret in Vault.**
Dashboard > project `ofezaezijafglyjmisgz` > Project Settings > JWT Keys >
Legacy JWT Secret. Reveal, copy. Then in the prod SQL editor:

    select vault.create_secret('<the real secret>', 'app_jwt_secret');

**2. PROVE the secret is right. Do not skip.**

    select verify_jwt_secret('<paste the prod anon key>');

Must return `true`. A wrong secret does not error: sign_in mints tokens, PostgREST
rejects every one, and the app comes up looking fine with every screen empty and no
error anywhere. This happened once already on the branch. Ninety seconds here saves
an hour of confusion.

**3. Run the migrations, prod SQL editor, in this order:**

    migrations/0002_pin_hashing.sql            -- plaintext PINs are destroyed here
    migrations/0004_auth_identity.sql          -- sign_in() + claim accessors
    migrations/0005_rls_identity_policies.sql  -- anon loses everything
    migrations/0006_kiosk_public_writes.sql    -- restores the two public tiles

0006 is NOT optional. 0005 alone breaks the two no-PIN member tiles on the login
screen (Weight Room Orientation Sign-Up, Book a Consultation). A member would fill
out the whole form and the save would 401. 0006 gives the kiosk a write-only
identity: it can INSERT a WRO and a consult client, and read nothing at all.

Each has a self-test that aborts rather than committing something broken.
**Sign-in is now broken until step 5.** The deployed app still speaks the old
plaintext-PIN protocol and the PINs no longer exist.

**4. Do NOT run `migrations/0003_rls_policies.sql`.** Retired. Kept for history.

**5. Ship the app.**

    git push
    git tag v4.46 && git push origin v4.46

Netlify auto-deploys in ~30s. Sign-in works again the moment it lands.

**6. Selisa: HARD-reload every iPad.** The wake sweep reloads data, not code. A
normal refresh may serve the cached bundle.

**7. Move the importers to `service_role`.** Set `SUPABASE_SERVICE_ROLE_KEY` in the
environment on the machine running the 5am/8am scheduled tasks (same place
`SUPABASE_ANON_KEY` lives today). Key from prod Project Settings > API.
**If you skip this, tomorrow's 5am intake import and 8am purchase import both fail
silently** - anon has no write grants anymore.

**8. Verify, from a signed-out browser on the production URL:**

    await supabaseClient.from('clients').select('*')

Must be denied. If it returns client rows, the lockdown failed. Roll back.

**9. Close it out.** Update-log entry + version tag per house rules.

### Rollback

`sql/rls_emergency_rollback.sql` disables RLS and re-grants anon. Note it does NOT
un-hash the PINs, and does not need to: the app after v4.46 signs in via
`sign_in()`, which works with RLS on or off. Do not redeploy the pre-v4.46 HTML -
it expects plaintext PINs that no longer exist.

---

## Phase 2 (ORIGINAL, SUPERSEDED - do not follow)

### The old list, kept for reference

Pick a low-traffic morning. Sequence matters because the old app compares
plaintext PINs that 0002 deletes - sign-in is briefly broken between steps 2
and 3 (about 2 minutes).

1. Pre-flight: `git status` clean, staging suite green within the last week,
   `sql/rls_emergency_rollback.sql` open in a SQL editor tab.
2. Prod SQL editor: run `migrations/0002_pin_hashing.sql`.
3. Port the app changes to `RoundRock_Fitness_Tracker.html` (checklist below),
   run node --check, commit, tag, push. Netlify deploys in ~30s.
4. Prod SQL editor: run `migrations/0003_rls_policies.sql`.
5. Add `SUPABASE_SERVICE_ROLE_KEY` to the environment on the machine that
   runs the 5am/8am imports (same place SUPABASE_ANON_KEY lives today).
   The key comes from prod Project Settings > API. Never in the repo.
6. Selisa: hard-reload every iPad (the wake sweep reloads data, not code),
   then sign in with her PIN, log a test entry, confirm sync indicator.
7. Watch the next 5am and 8am runs (or run both importers by hand with
   yesterday's files against prod, --dry-run first).
8. If anything unexplained breaks: run `sql/rls_emergency_rollback.sql`,
   which restores the open posture WITHOUT breaking sign-in (PIN RPCs keep
   working). Do not redeploy the old HTML - plaintext PINs no longer exist.
9. Update-log entry + version tag close the item, per house rules.

## App change checklist for the prod port (step 3)

All already applied and syntax-checked in the staging copy - diff it against
prod for the exact lines. Keep prod URL/key; everything else ports:

1. translate.trainers.toSupabase: stop writing `pin`.
2. translate.trainers.fromSupabase: `pin` -> `pin_set`.
3. Three profile constructors: `pin: null` -> `pin_set: false`.
4. Login startSignIn: `!profile.pin` -> `!profile.pin_set`.
5. Per-user PinModal call: `expected` -> `verify` via `verify_trainer_pin`
   RPC; onFail handles 'locked' / 'unset'.
6. Front desk PinModal call: `expected` -> `verify` via `verify_admin_pin`.
7. PinModal component: async `verify` support + busy state (legacy
   `expected` fallback retained).
8. TrainerEditModal: `pinAlreadySet` reads `pin_set`; audit strings use
   `pin_set`; `update.pin` write removed; `set_trainer_pin` RPC chained
   after the row update.
9. Manage Team: Front Desk PIN update via `set_admin_pin` RPC with a new
   current-PIN field.

## AMENDMENT 2026-07-13 - the `allow all` policies (blocker, now fixed)

An audit of the live database found twelve tables already carrying a policy
named `allow all` (`FOR ALL TO anon USING (true) WITH CHECK (true)`), inert
only because RLS was never enabled. `0003_rls_policies.sql` did not drop them.

Postgres OR's permissive policies. Enabling RLS with `allow all` still present
means anon keeps full ALL access, DELETE included, no matter what the new
policies say. Reproduced and confirmed on a throwaway table: with `allow all`
alongside `anon_select ... USING (key <> 'admin_pin')`, anon read the admin_pin
row anyway. Dropping `allow all`, changing nothing else, anon read zero.

Without the fix, this pass would have silently failed three of its four claims:
hard-deletes-closed, admin_pin-unreachable, and queue-closed. The Supabase
linter would have gone green. That is the worst possible outcome: a database
that looks locked, reports locked, and is not.

Fix applied to `0003_rls_policies.sql`: a STEP 0 block that drops all twelve,
plus a `DO $$` assertion that aborts the migration if any survive. Nothing else
in the pass changed. Re-run the staging suite before go-live to confirm the
DELETE and admin_pin assertions now behave as designed.

## AMENDMENT 2026-07-13 - the crypt() search_path bug (CRITICAL, now fixed)

Found by running the real migrations against a throwaway Supabase branch that
mirrored prod's exact starting state. This one would have taken the whole app
down on go-live morning with no way back.

`0002_pin_hashing.sql` declared its four PIN functions with:

    SET search_path = public, pg_temp

But `pgcrypto` is installed in the **`extensions`** schema on Supabase (verified
on production and on the test branch). `crypt()` and `gen_salt()` are therefore
NOT resolvable from `public, pg_temp`.

The failure mode is nasty because the migration itself appears to succeed:

1. The backfill (`INSERT INTO trainer_pins ... crypt(...)`) works, because
   migration scripts run with a wide search_path that includes `extensions`.
2. `UPDATE trainers SET pin = NULL` fires. Every plaintext PIN is destroyed.
3. The migration commits. Green checkmark.
4. First person to tap their tile gets
   `ERROR: function crypt(text, text) does not exist`. Sign-in is dead.
5. **`rls_emergency_rollback.sql` does not save you.** It states "the updated app
   verifies via RPC, which works with RLS on or off." It does not work. The RPC
   is broken independently of RLS.
6. **You cannot redeploy the old HTML either.** It compares plaintext PINs that
   step 2 already deleted.

Net: total, unrecoverable sign-in lockout of every production iPad, with the
team standing there, recoverable only by hand-writing SQL under pressure.

Fixes applied to `0002_pin_hashing.sql`:

- All four crypt-using functions (`verify_admin_pin`, `set_admin_pin`,
  `verify_trainer_pin`, `set_trainer_pin`) now declare
  `SET search_path = public, extensions, pg_temp`.
- A **SELF-TEST** block was added at the end of the migration. It calls
  `verify_trainer_pin` and `verify_admin_pin` for real before COMMIT. If they
  raise, the exception aborts the transaction, nothing is committed, the
  plaintext PINs survive, and the app keeps working. A broken PIN path can no
  longer reach production silently.

Verified on the branch after the fix: `verify_trainer_pin` returns `ok` for the
correct PIN, `wrong` for a bad one, and `locked` after five failures (and keeps
returning `locked` even when handed the correct PIN, so it doesn't leak).

Standing lesson: **never let a migration destroy the old credential path in the
same transaction that installs the new one, without proving the new one runs.**

## OPEN DECISION - do not defer per-user auth to APC

This pass, by its own design note, leaves anon with full read/write on the
operational tables. That means after go-live, anyone with the public URL can
still read every row of `clients`.

As of 2026-07-13 that is 15 clients, all 15 with email and phone, 4 with PAR-Q
health answers, 7 with session history. Plus 10 leads. Real Round Rock
residents, in a public database, with the credential published in a public repo.

The staged plan scopes the fix to "the APC gate (April 2027)." That was a
defensible call when this was a trainer-hours tracker. It is not defensible
heading into a beta that puts more resident PII and health-screen answers into
the same tables.

Recommended: treat per-user auth (PIN verified server-side already exists in
0002; what's missing is a signed JWT carrying trainer_id + role_tier, so
policies can key on identity instead of `true`) as the immediate next pass after
go-live, not an APC item. The scaffolding note in 0003 is right that this is a
policy edit rather than a rebuild. Do the edit.

Interim, if beta lands first: beta on synthetic client data. `sql/wipe_pre_alpha_clients.sql` exists.

## Known follow-ups (not this pass)

- Real per-user auth + row-scoped policies: APC gate (April 2027), or before
  any PHI flows through this app, whichever comes first. Note intake_paperwork
  already carries health-screen answers; worth raising the PHI question with
  IT sooner than APC.
- set_trainer_pin is not server-gated beyond the anon key (matches current
  posture; client-side canSetPINs gates the UI). Tighten with real auth.
- The pin_attempts lockout is per-scope, not per-device. Shared-iPad lockout
  hits everyone using that trainer tile for 5 minutes. Acceptable.
