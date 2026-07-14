# Round Rock Parks and Recreation - Fitness Tracker Update Log

**Live version: v4.46** (security pass, deployed July 14, 2026)

Newest version at the top; append new sections above the older ones.

> Canonical running log, version-controlled in `docs/`. It previously lived only
> as a Word doc outside git and drifted (a stale v4.29 copy caused confusion on
> July 10). Keep it here going forward. `npm run log:scaffold` produces the raw
> material (SHAs, diff stats, file lists) for new entries.

---

## Current standing - July 14, 2026

- **Live version: v4.46**, tagged and pushed; Netlify prod (pardfitnesstracker2)
  auto-deployed. Tracker file: 31,358 lines / 1.4 MB. `node --check` on the
  embedded JS: PASS.
- **The public exposure is closed.** Verified from a signed-out browser against
  the live production site after deploy:

      await supabaseClient.from('clients').select('*')
      -> BLOCKED: permission denied for table clients

  Earlier the same day that exact line returned all 15 client records, including
  4 PAR-Q health questionnaires. `trainer_directory` (names only, no PINs, no
  hashes) is now the only thing anyone on the internet can read.
- Data intact through the flip: 15 clients, 10 leads, 132 classes, 21 trainers.
- 13 plaintext PINs destroyed and bcrypt-hashed. Admin PIN hashed. RLS enabled on
  19 tables. Zero `allow all` policies survive. Supabase linter: zero
  `rls_disabled_in_public` errors.
- Both public member tiles (Weight Room Orientation, Book a Consultation) work,
  on a write-only kiosk token that can read nothing.
- **Both import pipelines cut over to `service_role`** and verified with a live
  authenticated read. They will run normally at 5am and 8am.
- Production migrations applied: **0002, 0004, 0005, 0006, 0007, 0008**.
  **0003 was retired and never run.**
- **anon now holds exactly ONE privilege in the entire `public` schema:**
  `trainer_directory:SELECT`. That is the correct end state and is worth
  re-asserting after any future migration that creates a table or view (see 0008).

### Still open

- **Rotate the anon key** pasted into chat on July 10. Now that RLS is on, the
  anon key is genuinely safe to be public, so this is hygiene rather than urgency.
  (Before v4.46, rotation would have fixed nothing: the key ships to every browser
  regardless. RLS is what makes a public key safe.)
- **Row ownership is still app-side**, not enforced by RLS. Any signed-in trainer
  can update any client's row. Structural, not laziness: sessions, packages and
  attendance live inside JSONB blobs on the parent row (ADR-0004), so "log a
  session" IS "UPDATE the whole clients row". Unwinding that is a separate
  project. Acceptable for an internal team tool; revisit before APC.
- `intake-import/README.md` still documents the retired no-write posture.
  SCHEMA.md autogen regions miss `pt_discharge` and `intake_paperwork`.
  Test-FMS cleanup SQL is committed but never run.
- `scripts/staging/rls_staging_test.py` asserts `PASS anon can select clients`,
  which was correct for the retired 0003 model and is a critical failure under the
  shipped model. `rls_identity_test.py` supersedes it. Retire the old one.

---

## v4.46 - July 14, 2026

The security pass. Takes the database from "anyone on the internet can read every
client record" to "you must be a signed-in team member, and the database enforces
it." Hashes every PIN, moves PIN verification server-side, gives the database a
real identity to key on, and enables RLS with policies that key on that identity
rather than on `true`.

### Trigger

A review of the Supabase security posture, prompted by a plain question: what
would change if RLS were turned on? The audit found the honest answer was "you
can't." There was no Supabase Auth in the codebase at all - no `supabase.auth.*`
call anywhere - so `auth.uid()` was always null and RLS had nothing to key on.
Sign-in was a client-side PIN comparison held in React state; the database never
learned who was asking. "Turn RLS on" was never actually an available move. The
real work was giving the database an identity first.

### Goal

Client names, emails, phones and PAR-Q health answers are not readable by the
public internet. The team signs in the way they always have (tap name, type a
4-digit PIN, on a shared iPad) and notices nothing different.

### File version

v4.46 - 31,358 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### Seven bugs, and how each was found

None of these were found by reading code. Every one surfaced by running the thing
against a real database. That is the whole lesson of this pass.

1. **The `allow all` policies. RLS would have been purely cosmetic.**
   Twelve tables already carried a policy named `allow all`
   (`FOR ALL TO anon USING (true) WITH CHECK (true)`), inert only because RLS was
   off. The staged `0003` never dropped them. Postgres OR's permissive policies
   together, so enabling RLS would have activated them and changed nothing: anon
   keeps full read/write, DELETE included. The Supabase linter would have gone
   green and the database would have stayed wide open. **That is the worst
   outcome available: believing you are done.**
   Reproduced on a throwaway table (with `allow all` alongside
   `anon_select ... USING (key <> 'admin_pin')`, anon still read the admin_pin
   row; dropping `allow all` and changing nothing else, anon read zero).
   Fixed with a STEP 0 drop block plus a `DO $$` assertion that aborts the
   migration if any `allow all` survives.

2. **The `crypt()` search_path bug. Total, unrecoverable sign-in lockout.**
   The four PIN functions in `0002` declared `SET search_path = public, pg_temp`,
   but `pgcrypto` lives in the `extensions` schema on Supabase, so `crypt()` is
   unresolvable at runtime. The migration *appears* to succeed: the backfill works
   (migrations run with a wide search_path), `UPDATE trainers SET pin = NULL`
   destroys every plaintext PIN, and it commits green. Then the first person taps
   their tile and gets `function crypt(text, text) does not exist`.
   `rls_emergency_rollback.sql` would not have saved us - it explicitly assumes
   "the PIN RPCs keep working," and they would not have; the failure is
   independent of RLS. The old HTML could not be redeployed either, because it
   compares plaintext PINs that step 2 just deleted. Net: every iPad locked out,
   no path back, recoverable only by hand-writing SQL under pressure.
   Fixed by adding `extensions` to the search_path, plus a SELF-TEST block that
   calls the RPCs for real before COMMIT.

3. **The token never reached PostgREST.** The first cut of the app wiring set
   `supabaseClient.rest.headers.Authorization`, assuming supabase-js reads that
   object at query time. It does not. Every request kept going out as anon and the
   app died on `permission denied for table trainers ... TO anon`.
   Fixed by injecting the token through a custom `global.fetch` passed to
   `createClient`: public API, runs on every PostgREST and RPC call, reads the
   token live, so an auth flip needs no client recreation and orphans no realtime
   channel.

4. **Spurious empty-array upserts. A data-loss bug, introduced by this pass.**
   The entity dirty-check refs initialise to `useRef(null)`, and `_saveIfDirty`
   treats `null` vs `[]` as dirty. The new pre-auth `loadAll` path hydrated only
   `trainerProfilesRef` and returned early, so the instant `loading` flipped false
   the app fired a SAVE for the other twelve entities - upserting **empty arrays
   over the server's data**. RLS is the only reason nothing happened; the console
   filled with `Save clients failed: permission denied`. On the open production
   database those writes would have LANDED.
   Fixed: the pre-auth path hydrates all thirteen refs, and doubles as the
   sign-out flush.
   **The lockdown caught a data-loss bug that the open database would have
   silently executed.**

5. **The kiosk regression. Caught at the go-live gate, minutes before the flip.**
   The login screen has two PUBLIC, no-PIN member tiles:

       "Weight Room Orientation Sign-Up"  -> upsertWRO()            -> writes `wros`
       "Book a Consultation"              -> auditedUpsertClient()  -> writes `clients`

   Both run with no token; both would have returned `permission denied`. A member
   fills in the entire orientation form, taps submit, and gets an error. The app
   even documents the intent (`Front Desk attribution when no session is active`).
   Granting anon the access back was not an option: the saves use
   `.upsert(..., {onConflict:'id'})`, which needs INSERT **and** UPDATE, and
   anon INSERT+UPDATE on `clients` is most of the door we just shut.
   Fixed in `0006` with a write-only kiosk identity (see Changes).

6. **PUBLIC execute on the PIN setters. Caught by the linter, after I asserted it
   was fixed.** Postgres grants EXECUTE to PUBLIC by default on function creation,
   and anon inherits through PUBLIC. `0005`'s `REVOKE ... FROM anon` therefore did
   nothing: anon could still reach `/rest/v1/rpc/set_trainer_pin` and
   `set_admin_pin`. Not exploitable (both check `app_is_admin() OR
   app_is_service_role()` and return `forbidden`), but that is one layer of
   defence where there should be two.
   Fixed in `0007` with `REVOKE ... FROM PUBLIC` plus a `has_function_privilege`
   assertion. **Verify, do not assume - including when the assertion comes from
   me.**

7. **`trainer_directory` was WRITABLE by anon. Live privilege escalation, found
   two hours after go-live, while double-checking work I had already called done.**
   Supabase ships DEFAULT PRIVILEGES granting ALL on newly-created objects in
   `public` to anon. `0005` ran `REVOKE ALL ON ALL TABLES ... FROM anon` at step 2
   and then `CREATE VIEW trainer_directory` at step 3. The view was born *after*
   the revoke, so it picked up the defaults: anon got INSERT, UPDATE, DELETE and
   TRUNCATE on it. A revoke cannot cover an object that does not exist yet.

   The view is SECURITY DEFINER (by design, so the login screen can read names
   pre-token) and auto-updatable, so writes through it execute as the view owner
   and **bypass RLS on `trainers` entirely.** Verified exploitable on production:

       anon UPDATEs trainers via the view ... 1 row
       anon INSERTs a trainer via the view .. 1 row
       anon DELETEs a trainer via the view .. blocked only by an incidental FK

   Anyone on the internet could insert, rename or modify team members. The delete
   failed only because that trainer happened to have notifications rows.

   Roster was writable for roughly two hours. Checked afterwards: 21 trainers,
   3 admins, zero rows created or updated in the window, no suspicious names.
   Nobody found it.

   Fixed in `0008`: `REVOKE ALL` then `GRANT SELECT` on the view, plus
   `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon` so
   the next object created cannot repeat it.

   **The policies were right. The GRANTS were wrong.** A policy audit says nothing
   about privileges. This was found only by enumerating
   `information_schema.role_table_grants` and asking why a number was 7 - after
   everything had been declared finished, verified, and shipped.

### Changes

**Database**

- **`0002_pin_hashing.sql`** - bcrypt-hashes every PIN into a `trainer_pins`
  table with no anon access, hashes the Front Desk PIN in place, moves
  verification into `verify_trainer_pin` / `verify_admin_pin` RPCs with a
  5-failures-in-15-minutes lockout, and drops the plaintext `trainers.pin` column.
  Carries the search_path fix and a self-test that aborts rather than committing a
  broken PIN path.
- **`0003_rls_policies.sql`** - **RETIRED, never run.** Every policy in it is
  `anon USING (true)`, which enables RLS but leaves `clients` world-readable. Kept
  in the repo for history only. Do not run it.
- **`0004_auth_identity.sql`** - gives the database an identity.
  `sign_in(trainer_id, pin)` delegates the PIN check to `verify_trainer_pin` (so
  it inherits the lockout for free) and returns a signed 12-hour JWT carrying
  `trainer_id` and `role_tier`. HS256, signed **inside Postgres** over pgcrypto's
  `hmac()`, with the project JWT secret held in Supabase Vault. **No Edge
  Function**: no Deno, no `supabase functions deploy`, no second deploy target, no
  function secret to rotate. Everything stays in a migration, which matches how
  this repo works. Also ships `sign_in_front_desk()` (the shared Front Desk seat
  has no `trainers` row, so `sign_in` had nothing to key on and would have been
  locked out of its own app) and `verify_jwt_secret()`.
- **`0005_rls_identity_policies.sql`** - the lockdown. Every policy keys on the
  JWT claims. anon loses all table grants. SELECT/INSERT/UPDATE require a
  signed-in team member; DELETE requires admin; `settings` (which holds the admin
  PIN hash) becomes admin-only, closing a self-escalation path; notifications are
  per-trainer. PIN setters become admin-gated with a `service_role` break-glass
  (without it, admin-only is a deadlock the day every admin forgets their PIN).
- **`trainer_directory` view** - the chicken-and-egg fix. You must pick your name
  before you can have a token, but you cannot read `trainers` without one. A
  definer view exposing names only. It is the single thing anon may read anywhere
  in the database. Includes the legacy `role` column deliberately: omit it and the
  pre-auth roster load hydrates every profile with `role='trainer'`, and the next
  Manage Team save silently downgrades every admin.
- **`0006_kiosk_public_writes.sql`** - restores the two public member tiles with a
  write-only identity. `sign_in_kiosk()` mints a 30-minute token with
  `role_tier='kiosk'`. **The load-bearing line:** `app_is_signed_in()` is
  redefined to mean "signed in AS A TEAM MEMBER"
  (`trainer_id IS NOT NULL AND role_tier <> 'kiosk'`). Every policy in 0005 keys
  on that function, so all of them - every SELECT, UPDATE and DELETE - stop
  applying to the kiosk instantly, without editing a single policy. Exactly two
  permissive INSERT policies are added back (`wros`, `clients`). A kiosk that
  sends an existing row id is still safe: ON CONFLICT DO UPDATE then evaluates the
  UPDATE policy, the kiosk has none, and the write is rejected.
- **`0007_revoke_public_execute_on_pin_setters.sql`** - `REVOKE ... FROM PUBLIC`
  on the PIN setters. See bug 6.
- **`0008_lock_trainer_directory_to_select_only.sql`** - `REVOKE ALL` +
  `GRANT SELECT` on the roster view, and `ALTER DEFAULT PRIVILEGES` so future
  objects do not inherit anon write access. See bug 7.

**App**

- Token injected via a custom `global.fetch` (not `rest.headers`, which silently
  does nothing - see bug 3).
- `realtime.setAuth()` on every auth change. Realtime enforces RLS **separately**
  from REST; miss this and `notifications` / `trainer_time_off` (the only two
  tables in the supabase_realtime publication) silently stop delivering with no
  error anywhere.
- `loadAll` re-runs on auth flip and has a pre-auth path: signed out, only the
  roster is reachable, so the app shows the login screen instead of "Couldn't
  connect to the server."
- The pre-auth path hydrates all thirteen dirty-check refs (see bug 4) and doubles
  as the sign-out flush.
- Sign-out clears the token centrally in `setSession`. There are a dozen
  `setSession(null)` call sites; leave the token behind at any one of them and the
  next person to pick up the iPad inherits the previous user's database credential
  for up to 12 hours.
- 12-hour token expiry watchdog. An iPad left signed in overnight would otherwise
  keep rendering as signed-in while every read returned empty and every write was
  rejected with no error the user ever sees - a trainer could log a whole morning
  of sessions into a void.
- `isStaff()` (not "do we have a token") gates the loaders, so the kiosk takes the
  pre-auth path and never tries to read tables it cannot see.
- Both PIN setters now handle a new `forbidden` status.

**Pipelines**

- Both importers cut over to `SUPABASE_SERVICE_ROLE_KEY` in their scheduled-task
  wrappers (gitignored). They already preferred it and fell back to anon, so this
  was a one-line change each.

### Test results

- `node --check` on the embedded JS - PASS
- **Five-seat verification against a real Supabase branch**, and the three team
  seats re-verified in a real browser:

  | | stranger | kiosk (member) | trainer | admin |
  |---|---|---|---|---|
  | read clients | DENIED | DENIED | yes | yes |
  | write clients | DENIED | INSERT only | yes | yes |
  | submit a WRO | DENIED | yes | yes | yes |
  | delete a client | DENIED | DENIED | DENIED | yes |
  | read admin PIN hash | DENIED | DENIED | DENIED | yes |
  | reset a PIN | forbidden | forbidden | forbidden | yes |
  | sign-in roster | yes | yes | yes | yes |

  A member submits an orientation request at the kiosk and a trainer then sees it.
  The workflow survives intact while the kiosk reads nothing.
- `sign_in` with a wrong PIN returns `wrong` and issues no token - PASS
- Lockout: 5 failures returns `locked`, and a *correct* PIN while locked still
  returns `locked` (it does not leak) - PASS
- Deploy verified on the live production site, signed out:
  `clients` BLOCKED, `leads` BLOCKED, anon write BLOCKED, roster 17 names - PASS
- Import pipelines proven with a live authenticated read:
  `SERVICE_ROLE: read 15 clients` / `ANON: blocked` - PASS
- Supabase security linter: zero `rls_disabled_in_public` errors. Remaining
  notices are deliberate (deny-all tables; login RPCs that must be anon-callable).
- Tagged v4.46 before push per tag-on-release.

### Deferred

- **Row ownership.** Any signed-in trainer can still update any client's row.
  Structural: sessions, packages and attendance live inside JSONB on the parent
  row (ADR-0004), so RLS cannot distinguish "log a session" from "edit someone
  else's client." Intra-team boundaries stay in `ctx.can()`. Acceptable for an
  internal team tool; it was never acceptable for the open internet, which is what
  this pass closes.
- **Class structure edits.** Marking attendance and editing class structure are
  both UPDATE on the same row, so RLS cannot tell them apart. Structure-edit
  remains an app-side `ctx.can()` gate.
- Anon key rotation (hygiene now, not urgency).
- Retire `rls_staging_test.py` in favour of `rls_identity_test.py`.
- README + ADR refresh for both auto-write pipelines.

### iPad test checklist for v4.46 specifically

- Load the site signed out. The trainer name list appears (that is
  `trainer_directory`). Open devtools and query `clients` - expect a permission
  error. **If that returns client data, the lockdown failed. Roll back.**
- Sign in with a PIN. Wrong PIN five times trips the lockout toast, and the
  *correct* PIN still says locked until it clears.
- Log a PT session, sign it, reload. It survives.
- Tap "Weight Room Orientation Sign-Up" as a member, submit the form, then sign in
  as a trainer and confirm the WRO appears on the board.
- Drop a class for sub coverage on one iPad, claim it on a second (confirms
  realtime is still authorized).
- As a non-admin, try to delete a client. The app blocks it and so does the
  database.
- As an admin, change a team member's PIN in Manage Team, then sign in with it.
- Leave an iPad signed in overnight. Next morning it should ask for the PIN again
  rather than silently failing every write.

### The lesson

Seven separate failures, and not one was caught by reading the code. The
`allow all` policies would have made RLS purely cosmetic while the linter went
green. The crypt bug would have locked the whole team out with no way back. My own
pre-auth path would have written empty arrays over live client records. The kiosk
regression would have been discovered by a confused member, not a log file. And
0007 was found by a linter *after I had told Reagan it was already fixed*.

And the last one, bug 7, is the sharpest of all: it was found AFTER the work was
declared finished, verified, shipped, documented and pushed - during a final audit
that existed only because the ask was "make sure this is correctly done." The
policies were all correct. The GRANTS were not, and nothing about a policy review
would ever have surfaced that.

Run it. Then check what actually happened. Then check the thing you did not think
to check. Assertions - including confident ones, including mine - are not
evidence.

---

## v4.45 - July 10, 2026

Automates PT-package population onto client profiles from RecTrac purchases, and
fills two catalog gaps. RecTrac already emails a daily "Training Packages Report"
and drops the CSV into a synced OneDrive folder; a new importer reads it and
attaches each purchase as a package on the matching client.

### Trigger
Packages were entered by hand. The RecTrac Training Packages Report (with
email/phone, package, dates, transaction type) was already landing in a local
OneDrive folder daily - an unused feed ready to drive package population.

### Goal
Purchases land as packages on the right client automatically, with no manual
entry, and new buyers who never did an intake still get a client record.

### File version
v4.45 - 30,966 lines, 1.32 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **`purchase-import/purchase_import.py`** (new) - reads the report CSV, maps
  each `pt_package` to a canonical type (exact map + pattern fallback that
  handles Baca zero-padding `03` and the `1st Time` intro), matches the buyer by
  email then phone, and PATCHes the package onto `client.packages` - or CREATEs
  the client from the row when there is no match. Idempotent by
  `(type, purchaseDate)` so re-running the daily/YTD report never double-adds.
  `Purchase -> rectrac_import`, `Renewal -> rectrac_reup`; `validDays` derived
  from the CSV's start/expiry. `--dry-run` is zero-write.
- **CMRC-Pairs-8 ($105) and CMRC-Pairs-12 ($145)** added to
  `PT_PACKAGES_BY_FACILITY` - both sold in RecTrac (confirmed in the YTD report)
  but were missing from the app catalog, so the importer could not map them.
- **Scheduled task "RRPR Purchase Import"** - 8am weekdays (after the ~7am
  report drop, so it processes same-day). Local wrapper + log gitignored.

### Test results
- `node --check` on the embedded JS - PASS
- `py_compile` on the importer - PASS
- Product-name mapper unit-tested against every live report name - PASS
- Dry-run then LIVE run against the real backlog verified: Tom Blaney's CMRC-PT-20
  appended alongside his existing package, Joy Brack created with CMRC-Pairs-12,
  Jayashree Ramanathan created with CMRC-PT-10; duplicate rows skipped
- Tagged v4.45 before push per tag-on-release

### Deferred
- RLS (see Current standing) - now doubly urgent with a second auto-write path
- README + ADR for the purchase importer's auto-write posture
- Rotate the Supabase key pasted into chat during setup

---

## v4.44 - July 10, 2026

Turns the intake into a pickable consult and puts the full packet in front of
the trainer. Each validated intake now provisions a client AND a linked
`waiting` lead in the consult queue; the same read-only packet render is shared
so it appears on the lead a trainer picks up, not just on the client.

### Trigger
The intake render (v4.43) only showed on a client, but a trainer working a
consult is looking at a lead, not a client yet - so the paperwork was invisible
at the moment it is most useful, and intakes did not feed the consult queue.

### Goal
A trainer picks up an intake as a consult lead and reads the whole
screening / goals / history inline; the intake feeds the consult queue the way
the architecture always intended.

### File version
v4.44 - 30,961 lines, 1.32 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Shared `IntakePaperworkSection` helper** - the ClientDetail packet render was
  extracted into a reusable, definition-driven (`INTAKE_SECTIONS`) function so
  ClientDetail and the consult queue render an identical packet.
- **LeadDetailModal renders the packet** from the lead's linked prospect client
  (`client.fromQueueId === lead.id`, read from `ctx.allClients`) - single source
  of truth, no `leads.intake_paperwork` column needed.
- **`ms_forms` added to `QUEUE_SOURCE_LABEL`** ("Microsoft Forms intake").
- **`intake_import.py`** now provisions both records: a client with
  `intake_paperwork` and a linked `waiting` lead (`source ms_forms`), wiring
  `client.from_queue_id = lead.id`. Dedup: existing client -> PATCH paperwork and
  add a lead only if none is open; new person -> create client, reuse an open
  lead or make one; junk -> review. Existing conversion machinery flips the lead
  to converted on first session log.

### Test results
- `node --check` on the embedded JS - PASS
- `py_compile` on the importer - PASS
- Dry-run then LIVE run verified: a lead was created for a re-dropped test
  intake, its linked client's `from_queue_id` points back to it, and the packet
  renders through the lead -> linked-client -> INTAKE_SECTIONS path
- Tagged v4.44 before push per tag-on-release

### Deferred
- RLS (see Current standing) - the intake path now also writes a lead per submit
- README/ADR update: the intake importer's no-write README is retired posture

---

## v4.43 - July 10, 2026

Locks the Intake Paperwork render to the real Pre-Assessment form. The live
Microsoft Forms export showed the assumed v4.40 shape had drifted in every
section, so intake-v2 replaces it field-by-field. Screening yes answers surface
as amber flags with a count chip, and a latent Yes/No string bug is fixed.
Shipped alongside (separate commits, not tracker versions): the intake-import
dropbox processor, later upgraded the same day to auto-create clients (`d19f7c3`).

### Trigger
Live Forms export of the CMRC Adult Fitness Pre-Assessment Packet (8 test
responses) surfaced shape drift against the assumed intake-v1 keys from v4.40.

### Goal
ClientDetail shows exactly what the member submitted, with screening flags
readable at a glance before a trainer ever meets the client.

### File version
v4.43 - 30,948 lines, 1.38 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **intake-v2 shape locked** - INTAKE_SECTIONS rebuilt field-by-field against the
  export: Participant (adds facility, consent), Health Screening (11 yes/no
  screens + surgery detail + details + medications), Exercise History (6
  free-text), Goals (short/long term), Lifestyle (nutrition, meals, sleep,
  stress, nicotine, alcohol). No production rows carried intake-v1, so no
  back-compat guard.
- **New `flag` field type** - screening yes/no where YES is the clinical finding.
  Renders amber instead of moss, distinct from neutral bool fields (consent,
  alcohol).
- **Screening flags header chip** - amber "N SCREENING FLAGS" chip counting yes
  answers across flag fields. Same semantics as the PAR-Q flag count in
  NewClientModal.
- **Yes/No coercion bug fix** - Forms sends "Yes"/"No" strings; the v4.40
  truthiness check would render "No" as a Yes pill. Both pill types now coerce
  through `intakeBool()`; empty string reads as unanswered and the row is skipped.

### Previously unversioned - folded into this window
Two app features shipped in the v4.43 window (ancestors of the v4.43 tag) without
their own version number; documented here rather than retro-tagged (tags kept
as-is):
- **sessions_low renewal alerts** (`51be225`) - low-session renewal alerts driven
  off the package_expiring sweep.
- **persist-then-toast infrastructure Batch A** (`31ca2d6`) - Patch G2 persist-
  then-toast scaffolding, no callers wired yet.

### Test results
- `node --check` on the embedded JS - PASS
- Single commit +90/-38, tagged v4.43 before push per tag-on-release
- `intake_import.py` offline tests exercise the same shape: normalize (Yes/No to
  booleans, M/D/YYYY to ISO, empty-string drop), match lanes, dollar-quoted JSONB
  with apostrophes - PASS

### Deferred
- RLS decision on the clients table - escalated to urgent by the same-day
  auto-write posture change (see Current standing)
- SCHEMA.md autogen refresh after the intake_paperwork column - also picks up the
  undocumented pt_discharge column
- Form cleanup: duplicate email questions - delete one so members cannot skip both

### iPad test checklist (v4.43)
- Submit a Forms test response for an existing client, let the pipeline run: all
  five sections render between Movement Screen and PT Discharge
- A yes on any screening question shows an amber Yes pill and the header chip
  shows the right flag count
- No answers render as No (this was the v4.40 string bug - verify explicitly)
- Unanswered questions produce no row; a client with no packet shows no section
- Completed date and MICROSOFT FORMS source pill render in the header

---

## v4.42 - July 9, 2026

Second half of the realtime load fix. Verification against the live
`supabase_realtime` publication (July 9) found only 5 tables actually publish
events; 8 of the app's 12 table-changes channels were subscribed to tables that
never emit - pure subscribe, sweep, and reconnect overhead on every iPad.

### Trigger
Follow-on from the v4.41 usage investigation: channel inventory against the live
publication showed 8 of 12 subscriptions were dead weight.

### Goal
Cut realtime message volume to what the publication can actually deliver, without
losing the wake catch-up refresh for the other entities.

### File version
v4.42 - 30,449 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **PUBLISHED_TABLES gate** - live channels open only for the 4 published entity
  tables (clients, classes, leads, trainer_time_off; notifications rides its own
  channel). The publication was verified 2026-07-09.
- **Wake refresh retained** - the 8 unpublished entities stay in the subscription
  list for wake-sweep catch-up, so they still converge on reload - they just no
  longer hold dead sockets.

### Test results
- Pre-push gates (`node --check` + tag check) - PASS
- Publication contents verified against the live database July 9 - note this
  supersedes the CLAUDE.md claim of 2 published tables from June 17

---

## v4.41 - July 9, 2026

Kills a self-sustaining realtime loop that had idle clients hammering Supabase at
roughly 180 classes UPDATE events per second with zero user input - about 5x the
Free-tier realtime message and egress caps, compounding daily.

### Trigger
Supabase usage running far over Free-tier caps with idle iPads - traced to the
realtime reload path.

### Goal
Stop the echo loop so idle devices generate near-zero load and the Free tier
holds until APC forces the infrastructure conversation.

### File version
v4.41 - 30,430 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Dirty-ref hydration on reload** - Root cause: realtime `reload()` called
  setState without hydrating the per-entity dirty-check ref (loadAll does). Every
  reload looked dirty, re-saved, the write echoed back as a postgres_changes
  event, and that retriggered reload. Worst on classes, whose JSONB round-trip is
  not stringify-stable. Reload now hydrates the ref, so echoes settle.
- **Wake sweep coalescing** - visibilitychange / online / pageshow reconnect
  sweeps coalesce instead of stacking, so an iPad waking from sleep fires one
  catch-up pass, not several.

### Test results
- Pre-push gates (`node --check` + tag check) - PASS
- Root cause reproduced from realtime event logs (~180 events/sec on classes with
  no user input) before the fix landed

---

## v4.40 - July 9, 2026

First cut of the Intake Paperwork render. Read-only ClientDetail section for the
CMRC Adult Fitness Pre-Assessment Packet stored as a single JSONB object on
`clients.intake_paperwork`. The original spec was not recoverable, so the field
shape was rebuilt from project memory and explicitly flagged as assumed - v4.43
corrected it the next day once the live form export existed. Shipping this cleared
the hold on the Section 5 decision-log pass (closed by ADR-0007 on Selisa's
verification).

### Trigger
The v4.39-era intake render spec was the standing blocker gating the Section 5
decision-log pass; spec text unrecoverable, rebuilt from project memory against
the pt_discharge and FMS patterns.

### Goal
Intake packets visible inside the app on the client record - no drive-diving
during a session - with a shape ready for the Forms ingestion pipeline.

### File version
v4.40 - 30,400 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Intake Paperwork section** - read-only render between Movement Screen and PT
  Discharge. Hidden entirely when absent for every tier (nothing to create
  in-app). Absent-guarded like pt_discharge, so it shipped safely before the DB
  column existed.
- **Definition-driven renderer** - INTAKE_SECTIONS constant is the single source
  of truth (CLEARING_TESTS pattern): renderer walks it, skips blanks and unknown
  keys, so the upstream shape can grow without breaking the render.
- **Helper lift** - boolPill and fieldRow lifted out of the PT Discharge IIFE to
  module scope as uiBoolPill / uiFieldRow for reuse.
- **Ingestion gap logged** - Microsoft Forms to Supabase ingestion added to
  BACKLOG.md as a separate build; intake_paperwork jsonb column SQL handed to
  Reagan (passthrough column, no translator entry needed).

### Test results
- `node --check` on the embedded JS - PASS
- Single commit +129/-14, tagged v4.40
- Render verified safe to deploy ahead of the ALTER TABLE: reads are null-guarded
  and no code path writes the key

### Deferred
- Field keys pending the live form export - resolved next day by v4.43
- iPad verification folds into the v4.43 checklist - v4.43 superseded this shape
  before it carried data, so test once against v4.43
