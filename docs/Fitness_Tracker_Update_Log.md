# Round Rock Parks and Recreation - Fitness Tracker Update Log

**Live version: v4.46 (security pass, deployed July 14, 2026).**

Newest version at the top; append new sections above the older ones.

> Canonical running log, now version-controlled in `docs/`. It previously lived
> only as a Word doc outside git and drifted (a stale v4.29 copy caused
> confusion on July 10). Keep it here going forward. `npm run log:scaffold`
> produces the raw material (SHAs, diff stats, file lists) for new entries.

---

## Current standing - v4.46 DEPLOYED July 14, 2026

- **The exposure is closed.** Verified from a signed-out browser against the live
  production site immediately after deploy:

      await supabaseClient.from('clients').select('*')
      -> BLOCKED: permission denied for table clients

  That is the exact line that returned all 15 client records, including 4 PAR-Q
  health questionnaires, earlier the same day. Reads of `leads` and anon writes
  to `clients` are blocked the same way. `trainer_directory` (17 names, no PINs,
  no hashes) is the only thing anyone on the internet can now see.
- Data intact through the flip: 15 clients, 10 leads, 132 classes, 21 trainers.
- 13 plaintext PINs destroyed and bcrypt-hashed. Admin PIN hashed. RLS enabled on
  19 tables. Zero `allow all` policies survive. Supabase linter: zero
  `rls_disabled_in_public` errors.
- Both public member tiles (Weight Room Orientation, Book a Consultation) render
  and work, on a write-only kiosk token that can read nothing.
- Migrations applied to production: 0002, 0004, 0005, 0006, 0007.
  **0003 was retired and never run.**
- **SEVEN bugs were caught before or during this go-live.** Five in staging (the
  `allow all` policies, the crypt search_path lockout, the rest.headers token
  failure, the empty-array upsert data-loss bug, the kiosk regression) and one
  during the flip itself (0007: PUBLIC execute on the PIN setters, caught by the
  Supabase linter after I had asserted it was revoked). Every one of them was
  found by actually running the thing rather than reasoning about it.

### Import pipelines - DONE, verified July 14

`SUPABASE_SERVICE_ROLE_KEY` is set in both scheduled-task wrappers
(`run_intake_import.cmd`, `run_purchase_import.cmd`, both gitignored). Both
importers already preferred it and fell back to anon, so this was a one-line
change each.

Proven live against production, not assumed:

    SERVICE_ROLE: read 15 clients  -> imports will work
    ANON: blocked                  -> the lockdown is working

Worth noting how nearly this was missed: both importers log `nothing to process`
and return BEFORE calling the API when the dropbox is empty, so "the task ran
without errors" proves nothing about whether the key is valid. The only real test
was a direct authenticated read. Two `INFO using service role key` lines looked
like success and were not.

### STILL OPEN
- Rotate the Supabase key pasted into chat on July 10. Now that RLS is on, the
  anon key is genuinely safe to be public, so this is hygiene rather than urgency.
- Row ownership remains app-side (`ctx.can()`), not enforced by RLS. Structural:
  sessions/packages live in JSONB on the parent row. Separate project.

---

## Superseded standing - audited July 13, 2026

- **Live version is still v4.45.** Nothing in v4.46 has touched production. The
  production database was audited on July 13 and is byte-for-byte where it
  started: 13 plaintext PINs, 15 clients, 12 policies, RLS off on all 17 tables.
- **v4.46 is the security pass. Fully staged, tested, not shipped.** It closes the
  exposure this log has been escalating since July 10. It ships as two deploys, in
  order, and the order is not optional (see the v4.46 entry).
- **The exposure, stated plainly, because it is still live right now:** the anon
  key is committed in the app, the app is public, the repo is public, and RLS is
  off. Anyone who opens the production URL and devtools can read and write every
  table. That currently includes 15 client records (all 15 with email and phone,
  4 with PAR-Q health answers, 7 with session history), 10 leads, and 13 team PINs
  in plaintext.
- **Decision made July 13: client data must not be publicly viewable.** This
  retires the previously-staged plan, which enabled RLS but kept
  `anon USING (true)` on the operational tables and deferred real per-user auth to
  the APC gate (April 2027). Under that plan `clients` stayed world-readable after
  go-live. Migrations `0004` + `0005` replace it with identity-based policies.
- **Two live-fire bugs were found in the previously-staged work.** Either would
  have caused an incident on go-live morning. Both are written up in the v4.46
  entry. Neither would have been caught without actually running the migrations,
  which is the lesson.
- Both import pipelines still auto-write to prod through the public anon key. They
  move to `service_role` as part of v4.46 Deploy 1.
- **Credential hygiene:** the Supabase key pasted into chat on July 10 is still
  unrotated. Note that rotation alone fixes nothing while RLS is off - the key
  ships to every browser regardless. RLS is what makes the key safe to publish.
- Still open from July 10: `intake-import/README.md` documents the retired
  no-write posture; `purchase-import/` has no README; no ADR captures either
  auto-write pipeline; SCHEMA.md autogen regions miss `pt_discharge` and
  `intake_paperwork`; Test-FMS cleanup SQL is committed but never run.

---

## v4.46 - July 14, 2026 - DEPLOYED

The security pass. Takes the database from "anyone on the internet can read every
client record" to "you must be a signed-in team member, and the database checks."
Hashes every PIN, moves PIN verification server-side, gives the database a real
identity to key on, and enables RLS with policies that key on that identity rather
than on `true`.

Nothing here has touched production. Two bugs in the previously-staged work were
found by running it for real against a throwaway Supabase branch. Both would have
caused a production incident.

### Trigger
A review of the Supabase security posture. The audit found no Supabase Auth in the
codebase at all - no `supabase.auth.*` call anywhere - which meant `auth.uid()` was
always null and RLS had no identity to key on. "Turn RLS on" was never actually
available as a move; the real work was giving the database an identity first.

### Goal
Client names, emails, phones, and PAR-Q health answers are not readable by the
public internet. The team signs in the way they always have (tap name, type PIN, on
a shared iPad) and notices nothing different.

### File version
v4.46 - staging file 31,265 lines, 1.40 MB
(`staging/RoundRock_Fitness_Tracker.staging.html`). Prod file untouched at v4.45 /
30,966 lines.

### The two bugs found

- **The `allow all` policies. RLS would have been cosmetic.** Twelve tables already
  carried a policy named `allow all` (`FOR ALL TO anon USING (true) WITH CHECK
  (true)`), inert only because RLS was off. `0003_rls_policies.sql` never dropped
  them. Postgres OR's permissive policies together, so enabling RLS would have
  activated them and changed nothing: anon keeps full read/write, DELETE included.
  The Supabase linter would have gone green and the database would have stayed wide
  open. Reproduced on a throwaway table: with `allow all` sitting alongside
  `anon_select ... USING (key <> 'admin_pin')`, anon still read the admin_pin row;
  dropping `allow all` and changing nothing else, anon read zero. Without the fix,
  three of that migration's four stated wins silently failed (hard-deletes-closed,
  admin_pin-unreachable, queue-closed). Fixed with a STEP 0 drop block plus a
  `DO $$` assertion that aborts the migration if any `allow all` survives.

- **The `crypt()` search_path bug. Total, unrecoverable sign-in lockout.** The four
  PIN functions in `0002_pin_hashing.sql` declared `SET search_path = public,
  pg_temp`, but `pgcrypto` is installed in the `extensions` schema on Supabase
  (verified on prod and on a test branch), so `crypt()` is not resolvable at
  runtime. The migration *appears* to succeed: the backfill works (migrations run
  with a wide search_path), `UPDATE trainers SET pin = NULL` destroys every
  plaintext PIN, and it commits green. Then the first person taps their tile and
  gets `function crypt(text, text) does not exist`.
  `rls_emergency_rollback.sql` does not save you - it explicitly assumes "the PIN
  RPCs keep working," and they do not; the failure is independent of RLS. The old
  HTML cannot be redeployed either, because it compares plaintext PINs that step 2
  just deleted. Net: every production iPad locked out, no path back, recoverable
  only by hand-writing SQL under pressure, on a morning chosen because Selisa was
  available. Fixed by adding `extensions` to the search_path, plus a SELF-TEST
  block that calls the RPCs for real before COMMIT, so a broken PIN path can never
  reach production silently again.

### Two more bugs, found only in a real browser

The SQL layer was green and the migrations were provably correct. Both of these
still got through, and neither would ever have surfaced without loading the app
against a locked-down database.

- **The token never reached PostgREST.** The first cut of the app wiring set
  `supabaseClient.rest.headers.Authorization`, on the assumption that supabase-js
  reads that object at query time. It does not. Every request kept going out as
  anon and the app died on `permission denied for table trainers ... TO anon`.
  Fixed by injecting the token through a custom `global.fetch` passed to
  `createClient` - public, supported API, runs on every PostgREST and RPC call,
  reads the token live, so an auth flip needs no client recreation and orphans no
  realtime channel.

- **Spurious empty-array upserts. This one was a data-loss bug.** The entity
  dirty-check refs initialise to `useRef(null)`, and `_saveIfDirty` treats
  `null` vs `[]` as dirty. The new pre-auth `loadAll` path hydrated only
  `trainerProfilesRef` and returned early, so the instant `loading` flipped false
  the app fired a SAVE for the other twelve entities - upserting **empty arrays
  over the server's data**. RLS is the only reason nothing happened; the console
  filled with `Save clients failed: permission denied`. On production, where anon
  can still write, those upserts would have LANDED. Fixed: the pre-auth path now
  hydrates all thirteen refs, and doubles as the sign-out flush (entities reset to
  a shared `EMPTY` reference the refs also point at, so the identity check
  short-circuits and no save fires).

  Worth stating plainly: the lockdown caught a data-loss bug that the open
  database would have silently executed.

### A fifth bug, caught at the go-live gate

Found while doing the final pre-flight read of the login screen, minutes before
the flip. The lockdown would have broken both PUBLIC member-facing tiles:

    "Weight Room Orientation Sign-Up"  -> setSession({role:'kiosk_wro'}) -> writes `wros`
    "Book a Consultation"              -> auditedUpsertClient()          -> writes `clients`

Both are no-PIN, member-operated self-service flows. The app even documents the
intent (`Front Desk attribution when no session is active`). Under 0005 both run
with no token, so both return `permission denied`. A member fills in the entire
orientation form, taps submit, and gets an error.

Granting anon the access back was not an option: the saves use
`.upsert(..., {onConflict:'id'})`, which needs INSERT **and** UPDATE, and handing
anon INSERT+UPDATE on `clients` is most of the door we just shut.

Fixed in **`0006_kiosk_public_writes.sql`** with a write-only kiosk identity:

- `sign_in_kiosk()` mints a 30-minute token with `role_tier='kiosk'` and a
  sentinel trainer_id. No PIN, because these are public tiles.
- **The load-bearing line:** `app_is_signed_in()` is redefined to mean "signed in
  AS A TEAM MEMBER" (`trainer_id IS NOT NULL AND role_tier <> 'kiosk'`). Every
  policy in 0005 keys on that function, so all of them - every SELECT, UPDATE and
  DELETE - stop applying to the kiosk instantly, without editing a single policy.
- Exactly two permissive INSERT policies are added back: `wros` and `clients`.
- A kiosk that sends an EXISTING row id is still safe: ON CONFLICT DO UPDATE then
  evaluates the UPDATE policy, the kiosk has none, and the write is rejected. It
  cannot overwrite a real client by guessing a uuid.
- App: the two tiles now call `sign_in_kiosk()` before entering the flow, and
  `isStaff()` (not "do we have a token") gates the loaders, so the kiosk takes the
  pre-auth path and never tries to read tables it cannot see.

Verified on a branch: kiosk submits a WRO and books a consult client; reads
clients, wros and settings all return 0; update and delete both affect 0 rows; and
a trainer then sees exactly what the kiosk submitted. The member-to-trainer
workflow survives intact while the kiosk reads nothing.

### Changes

**Deploy 1 - PIN hashing and pipeline lockdown (tested, ready)**

- **`migrations/0002_pin_hashing.sql`** (fixed) - bcrypt-hashes every PIN into a
  `trainer_pins` table with no anon access, hashes the Front Desk PIN in place,
  moves verification into `verify_trainer_pin` / `verify_admin_pin` RPCs with a
  5-failures-in-15-minutes lockout, and drops the plaintext `trainers.pin` column.
  Now carries the search_path fix and the self-test.
- **`migrations/0003_rls_policies.sql`** (fixed) - adds the STEP 0 `allow all` drop
  and the abort assertion. **Superseded by 0005 and should NOT be run** under the
  July 13 decision: every policy in it is `anon USING (true)`, which leaves
  `clients` world-readable. Kept for history.
- **Both import pipelines** move off the anon key to `service_role`.

**Deploy 2 - identity RLS (the pass that actually closes client data)**

- **`migrations/0004_auth_identity.sql`** (new) - gives the database an identity.
  `sign_in(trainer_id, pin)` delegates the PIN check to the existing
  `verify_trainer_pin` (inheriting the lockout for free) and returns a signed
  12-hour JWT carrying `trainer_id` and `role_tier`. HS256, signed in Postgres over
  pgcrypto's `hmac()`, with the project JWT secret held in Supabase Vault. **No
  Edge Function**: no Deno, no `supabase functions deploy`, no second deploy target,
  no function secret to rotate. Everything stays in a migration, which matches how
  this repo works. Ships `app_trainer_id()`, `app_role_tier()`, `app_is_admin()`,
  `app_is_signed_in()` claim accessors, all fail-closed.
- **`sign_in_front_desk(pin)`** (new) - Front Desk is a shared seat with no row in
  `trainers`, so `sign_in(trainer_id, pin)` had nothing to key on. Without this,
  switching on identity RLS would have locked Front Desk out of its own app. Mints
  a token against the nil UUID with `role_tier=admin`.
- **`migrations/0005_rls_identity_policies.sql`** (new) - replaces 0003's anon
  policy set. Every policy keys on the JWT claims. anon loses all table grants.
  SELECT/INSERT/UPDATE require a signed-in team member; DELETE requires admin;
  `settings` (which holds the admin PIN hash) becomes admin-only, closing a
  self-escalation path; notifications are per-trainer.
- **`trainer_directory` view** (new) - the chicken-and-egg fix. You must pick your
  name before you can have a token, but you cannot read `trainers` without one. A
  definer view exposing names only (no PIN, no hash, no audit_log). It is the single
  thing anon may read anywhere in the database. Includes the legacy `role` column
  deliberately: omit it and the pre-auth roster load hydrates every profile with
  `role='trainer'`, and the next Manage Team save silently downgrades every admin's
  role column.
- **`set_trainer_pin` / `set_admin_pin` become admin-gated.** 0002 shipped these
  with the note "not server-gated beyond the anon key ... tighten with real auth."
  This is that tightening. Without it, anyone holding the public key could reset any
  team member's PIN and sign in as them. A `service_role` branch is the bootstrap
  and recovery door - without it, admin-only is a deadlock waiting for the day every
  admin forgets their PIN.
- **App: auth token module** - carries the JWT on both surfaces that need it.
  PostgREST (by overwriting `client.rest.headers.Authorization`, which supabase-js
  re-reads per call, so no client recreation and no orphaned channels) and Realtime
  (via `realtime.setAuth`, which is enforced separately - miss it and
  `notifications` / `trainer_time_off`, the only two tables in the
  supabase_realtime publication, silently stop delivering with no error anywhere).
- **App: `loadAll` re-runs on auth change and has a pre-auth path.** Signed out,
  every table except `trainer_directory` is denied, so the old unconditional
  `Promise.all` would reject on the first blocked table and drop the user on the
  "Couldn't connect to the server" error screen instead of the login screen. The app
  would look broken to someone who simply had not signed in yet.
- **App: sign-out clears the token, centrally in `setSession`.** There are a dozen
  `setSession(null)` call sites. Leave the token behind at any one of them and the
  next person to pick up the iPad inherits the previous user's database credential
  for up to 12 hours.
- **App: token expiry watchdog.** An iPad left signed in overnight would keep
  rendering as signed-in after the 12-hour token lapsed, while every read returned
  empty and every write was rejected with no error the user ever sees. A trainer
  could log a whole morning of sessions into a void. Now it signs out loudly and
  asks for the PIN again. Checked on an interval and on wake, because a sleeping
  iPad's timers do not fire.

### Test results

Verified against a real Supabase branch seeded to mirror prod's exact starting
state (12 `allow all` policies, plaintext PINs, plaintext admin PIN):

- `node --check` on the embedded JS - PASS
- **Full three-seat verification in a real browser against a real database**
  (Chrome, app served from `staging/local-branch.html` against a Supabase branch):

  | | stranger (public key) | trainer | admin |
  |---|---|---|---|
  | read clients | DENIED | yes | yes |
  | write clients | DENIED | yes | yes |
  | delete client | DENIED | DENIED | yes |
  | read admin PIN hash | DENIED | DENIED | yes |
  | reset a PIN | forbidden | forbidden | yes |
  | sign-in roster | yes (names only) | yes | yes |

  Same code, same public key, same browser. Production today answers "yes" to
  every cell in the stranger column.
- `sign_in` wrong PIN returns `wrong` and issues no token - PASS
- The anon seat, over real PostgREST: `anon CANNOT read clients` (permission
  denied), `anon CAN read trainer_directory` (login screen works) - PASS
- The trainer seat: reads clients, inserts, updates - PASS. Cannot DELETE, cannot
  read `settings`, cannot reset another PIN, cannot see another trainer's
  notifications - PASS
- The admin seat: reads `settings`, deletes clients, resets PINs - PASS
- `sign_in` mints a 3-segment JWT; claims decode to `role=authenticated`,
  `trainer_id`, `role_tier`, 12-hour exp - PASS
- Lockout: 5 failures returns `locked`, and a *correct* PIN while locked still
  returns `locked` (it does not leak) - PASS
- Deploy 1 over real PostgREST via `rls_staging_test.py`: 27 passed. anon cannot
  read admin_pin / trainer_pins / pin_attempts / packages / package_participants /
  queue - PASS. Both bug fixes confirmed through the real HTTP layer, not just SQL.
- Production confirmed untouched after all of it: 13 plaintext PINs, 15 clients,
  12 policies, 0 tables with RLS on

### Deferred

- **Row ownership.** Any signed-in trainer can still update any client's row.
  Structural, not laziness: sessions, packages, and attendance live inside JSONB
  blobs on the parent row (ADR-0004), so "log a session" IS "UPDATE the whole
  clients row." RLS cannot tell that apart from an edit to someone else's client.
  Unwinding the JSONB model is a separate project. Intra-team boundaries stay in
  `ctx.can()`. This is an acceptable trust boundary for an internal team tool; it was
  never acceptable for the open internet, which is what this pass closes.
- **Class structure edits.** Marking attendance and editing class structure are both
  UPDATE on the same row, so RLS cannot distinguish them. Structure-edit remains an
  app-side `ctx.can()` gate.
- Anon key rotation (worth doing at cutover for hygiene, but it changes nothing on
  its own - the key is public by design and ships in the HTML either way; RLS is what
  makes it safe to publish).
- README + ADR for both auto-write pipelines.
- `rls_staging_test.py` still asserts `PASS anon can select clients`, correct for the
  Deploy 1 model and a critical failure under the Deploy 2 model.
  `rls_identity_test.py` supersedes it. Retire the old one after cutover.

### iPad test checklist for v4.46 specifically

- Load the site signed out. The trainer name list appears (that is
  `trainer_directory`). Open devtools and try to query `clients` - expect zero rows
  or a permission error. **If that returns client data, the lockdown failed. Stop and
  roll back.**
- Sign in with a PIN. Wrong PIN five times trips the lockout toast, and the *correct*
  PIN still says locked until it clears.
- Log a PT session, sign it, reload the page. It survives.
- Drop a class for sub coverage on one iPad, claim it on a second. Confirms realtime
  is still authorized (`realtime.setAuth` is wired).
- As a non-admin, try to delete a client. The app blocks it, and so does the database.
- As an admin, change a team member's PIN in Manage Team, then sign in with it.
- Leave an iPad signed in overnight. Next morning it should ask for the PIN again
  rather than silently failing every write.

---

## Standing as of July 10, 2026 (superseded by the July 13 audit above)

- **Live version: v4.45**, tagged and pushed; Netlify prod (pardfitnesstracker2)
  auto-deployed. Tracker file: 30,966 lines / 1.32 MB. `node --check` on the
  embedded JS at HEAD: PASS.
- Everything is pushed - local `main` equals `origin/main`. The only local-only
  work is Reagan's in-progress Playwright local-test files (untracked) and
  matching `package.json` script edits.
- **[Resolved]** The two previously-unversioned features - sessions_low renewal
  alerts (`51be225`) and persist-then-toast infrastructure Batch A (`31ca2d6`) -
  are now documented under the v4.43 window (see that entry). Tags kept as-is
  per decision; not retro-tagged. v4.44 / v4.45 are the two new features below.
- **Two live import pipelines now auto-write to prod through the public anon
  key, on scheduled Windows tasks:**
  - **Intake** - Forms -> Power Automate -> OneDrive dropbox -> `intake_import.py`,
    5am daily. As of v4.44 it creates a client AND a linked `waiting`
    consult-queue lead; the full packet renders on the lead in LeadDetailModal.
  - **Purchase** - RecTrac Training Packages Report CSV -> OneDrive drop folder
    -> `purchase_import.py`, 8am weekdays. Attaches packages to matched clients
    and creates client rows for unmatched buyers (backfill).
- **RLS on the clients/leads tables is URGENT (escalated further).** Two
  importers now auto-write through the committed anon key: intake writes
  health-screening PHI (client + lead), purchase writes package/financial data
  and auto-creates client rows. Public-anon-key writes of PHI and auto-created
  records is not the right posture for live data. This was acceptable-for-
  prototype before any of this data existed; it is not now.
- **Paper-trail drift:** `intake-import/README.md` still documents the retired
  no-write posture; `purchase-import/` has no README; NO ADR captures either
  auto-write pipeline. CLAUDE.md's realtime section still says 2 published
  tables (June 17) versus the 5 verified July 9.
- **Credential hygiene:** a Supabase key was pasted into a working chat during
  setup on July 10 - rotate it. The scheduled tasks correctly use the
  designed-public anon key (RLS disabled, so it authorizes the writes).
- SCHEMA.md autogen regions are missing the `pt_discharge` and
  `intake_paperwork` columns - run `npm run schema:check -- --write` against the
  live DB. (Note: `leads` has no `intake_paperwork` column by design - the
  packet stays on the client and renders on the lead via `fromQueueId`.)
- Test-FMS cleanup SQL (`4cb4a1a`) is committed and preview-gated but has not
  been run against the database.

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
