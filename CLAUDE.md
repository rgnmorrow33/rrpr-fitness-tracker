# Round Rock Fitness Tracker - Claude Code Project Notes

This file is read at the start of every Claude Code session.
It encodes the conventions, decisions, and gotchas for this repo.

## What this is

Single-file HTML web app deployed on iPads at Round Rock Parks
and Recreation fitness facilities (Clay Madsen Recreation Center
and Allen R. Baca Center, with APC opening April 2027). Used by
trainers, instructors, front desk, and division administration to
track PT clinic operations, group exercise, personal training,
and member engagement.

Architecture: React 18 from CDN, no build step. All HTML, CSS, JS
in one file: RoundRock_Fitness_Tracker.html. Currently storing
data in Supabase via the storage adapter at the top of the file.

## Who uses Claude Code on this repo

Reagan (primary owner). Defines specs in a separate Claude web chat,
pastes prompts here. Selisa (Assistant Head of Facilities, CMRC) is
the QA partner. She does not use Claude Code; she runs Supabase
schema changes and tests on production iPads.

## Working conventions

### Diagnostic before fix
When something is unclear, investigate and report back BEFORE editing.
Do not guess at the cause. Use grep, file reads, and code inspection
to confirm the actual bug location.

### Plan before edits on big changes
For multi-component or architectural changes, propose the plan first
(which existing pattern is being reused, where the new code fits,
which call sites need updating). Confirm before applying.

### Batch edits in one commit
Multiple related fixes ship together as one commit with a descriptive
batched message. Avoids one-deploy-per-fix and easier rollback.

### Validate before push
Always run node --check on the embedded JS before commit. Catches
syntax errors before they reach Netlify.

### Defer non-urgent cleanups
Spotted an adjacent code smell during a fix? Flag it, don't fix it
in the same commit. Cleanups go in a dedicated commit later.

### No line-number references in docs
Docs in `/docs` (SCHEMA.md, ARCHITECTURE.md, DECISIONS.md, BACKLOG.md)
reference code in `RoundRock_Fitness_Tracker.html` by function name or
section anchor, never by line number. The single-file app drifts; line
refs go stale within days.

## Writing conventions in user-facing code

- No em dashes. Use space-hyphen-space ( - ), parentheses, or two
  sentences instead.
- "Team" never "staff."
- First-name-only sign-offs in any UI text.
- Casual, conversational voice.
- No corporate filler.

## Color palette

- Navy: 1B3D5C
- Teal: 2E8B8B
- Gold: C49A4A
- Cream: F4EFE6
- Slate: 5C6970
- Border: D9D2C4

Status colors: red for critical/loss, green for success/converted,
amber for warning/aged.

A forest green / sage / pine palette rebrand is queued as a
dedicated commit. Do not ship inside a feature batch.

## Storage architecture

The app uses a storage adapter (the `storage` object near the top of
the embedded script, just after the config constants) that wraps all
reads/writes. Two modes: 'localStorage' and 'supabase'. Currently in
'supabase' mode.

Supabase project: ofezaezijafglyjmisgz.supabase.co
Anon key is committed in the file (designed-public). RLS is disabled
project-wide, so the key is NOT RLS-gated - access is open at the DB
layer. See Security posture.

Storage adapter exposes: storage.X.load() / storage.X.save(arr) for
each entity. Returns Promises in both modes.

Translation layer (translate.X.toSupabase / fromSupabase) handles
camelCase to snake_case conversion at the storage boundary. The
in-memory shape stays camelCase; only Supabase writes/reads use
snake_case. Field-by-field translation maps live in translate.X.

### Entity to Supabase table name mapping

- storage.clients = clients
- storage.classes = classes
- storage.wros = wros
- storage.leads = leads
- storage.contacts = member_contacts
- storage.adminItems = admin_items
- storage.referrals = referrals
- storage.closures = closures
- storage.trainers = trainers
- storage.scheduleVersions = schedule_versions

### Local-only fields

Some lead fields don't have Supabase columns and are device-local:
followUpBy, rectracMemberId, packageInfo, lostAt. These get dropped
on write to Supabase and don't survive round-trip. Acceptable trade-
off for now.

### WROs JSONB split

The wros table has flat columns (trainer_name, client_name, date,
notes, signature_data) plus a `data` jsonb column. Pre-form goals,
post-form claim state, and conversion lifecycle live in `data`.

### Saves use dirty-check refs

Each entity's save useEffect compares current state to a ref via
JSON.stringify (timestamps stripped) before saving. Prevents pointless
network writes on unchanged data.

## Real-time subscriptions

CRITICAL GOTCHA - most tables do NOT sync live. The app attaches
postgres_changes listeners for 12 entity tables on the 'app-changes'
channel, but the supabase_realtime publication contains only 2 tables
(notifications and trainer_time_off, verified June 17). A listener
receives nothing unless its table is in the publication. Net effect:
only trainer_time_off syncs live on app-changes; notifications syncs
live on its own per-trainer channel; every other entity converges only
on reload (navigation / mount-fetch / wake sweep), not live push. To
make a table sync live you must ADD IT TO the publication - attaching a
client listener alone does nothing. Do not design a feature assuming a
table pushes live without confirming it is in the publication.

Full mechanics (reload chain, self-write echo tolerance, reconnect,
wake sweeps, notifications channel, sync indicator) live in
ARCHITECTURE.md section 6. Load it before touching realtime code.

## Permission model

Core principle: trainers EXECUTE, admins set STRUCTURE.

Trainers can: log sessions, mark attendance, sign, drop class for
sub coverage, claim sub, mark single occurrence cancelled, trigger
service recovery, add new package (re-up).

Admins only: delete a client, delete a class, delete a signed
session (both signatures present), edit class structure (name, day,
time, capacity), change package type, manage trainer roster,
override claim or release.

## Session lifecycle

Attended: both trainer and client sign. Counts against package.

No-show: trainer signs, client cannot. FULL session loss. NO SHOW
badge. Triggers service recovery popup.

Late cancel (under 24 hr): FULL session loss. LATE CANCEL badge.
Three per episode = discharge consideration.

Excused: note preserved, no loss, EXCUSED badge.

Service recovery: free text required, duration auto-matches lost
session/class length, counts as ADMIN time, separate line item on
time card.

## Hours math conventions

- GX classes 50-60 min count as 1.0 hr; otherwise actual duration
- Auto-admin = 0.25 x forward-facing hours, applied automatically
- Manual admin: Program Creation, Training, Community Event, Other
- Member contacts: Quick = 2 min, Substantive = 6 min, Educational = 15 min, capped 4 hr/period
- Service recovery: capped at lost session/class duration
- PT session duration: 1 hour or 30 minutes (chosen at log time)

## Deployment pipeline

- Repo: github.com/rgnmorrow33/rrpr-fitness-tracker (PUBLIC)
- Hosting: Netlify with auto-deploy from main
- Production site: pardfitnesstracker (Selisa's iPads)
- Test site: pardfitnesstracker2 / candid-cendol-66c876
- Local repo: C:\Docs\rrpr-fitness-tracker

Workflow:
1. Reagan describes change in Claude Code
2. Claude Code edits the file
3. node --check on embedded JS
4. git add, commit with descriptive message, git push
5. Netlify auto-deploys in ~30 seconds
6. Selisa verifies on production iPad

Pre-push gates. Two checks run before every push and block it on failure:
node --check on the embedded JS, and the tag-before-push check. They run
two ways - through Claude Code automatically (.claude/settings.json), and
as a native git pre-push hook for manual terminal pushes. The git hook is
tracked in githooks/ but core.hooksPath is local config, so each clone
enables it ONCE:

    git config core.hooksPath githooks

Do NOT rename the tracker file. The netlify.toml redirect handles
serving RoundRock_Fitness_Tracker.html at the root URL.

Do NOT put the repo in a OneDrive-synced folder. Conflicts with
Git's .git folder.

## Version tagging (tag on release)

Every shipped version gets a lightweight git tag at release. Tag BEFORE
pushing the version's commits, then push the branch, then push the tag:

    git tag v4.32
    git push
    git push origin v4.32

Tag-before-push is enforced: the pre-push hook (see Deployment pipeline)
blocks any push whose commits reference a `vX.Y` that has no matching tag.
The tag still marks the exact commit that goes live as that version.

Why: versions otherwise live only as inline comments and in the update-log docx,
which makes version-to-version history archaeology (this caused the v4.30/v4.31
reconstruction problem). Tags give the log scaffold (`npm run log:scaffold`) clean
ranges with no argument, let the SCHEMA.md checker stamp drift reports against a
known version, and mean future-me never has to guess whether a version existed.

Rule: a version is not done until it is tagged. The update-log entry and the tag
are the two closing acts of shipping a version. If you used the tag+scaffold
helper (`npm run release:tag -- v4.32`), the tag is handled; otherwise tag by hand.

Tags are cheap and local-cost-free. This is a habit, not a process. No annotated
tags, no release notes in the tag, no signing. Just `git tag vX.Y`.

## Required field validation

- Name required on new client and WRO intake
- At least ONE of email or phone required (both is fine, minimum one)
- Email must look like email@domain.something when provided
- Phone must have at least 10 digits when stripped
- Existing records grandfathered

## Deferred work

Deferred work (cleanup pile, refactor targets, unbuilt features) lives
in docs/BACKLOG.md, load on demand.

## Security posture

RLS is DISABLED across all 17 public tables (verified June 17). Reads
and writes go through the committed anon key with no RLS gating -
access is open at the DB layer. Acceptable for prototype. Tighten
(enable RLS, add policies) before APC opens (April 2027) or before any
clinical PHI flows through the system, whichever first.

PIN is in the settings table. Plaintext for now. Hash before APC opens.

## Out of scope

- Payment processing (RecTrac handles)
- Member self-service portal (RecTrac handles)
- Clinical PT EMR (PTEverywhere is separate, not connected to this app)
- Email/SMS infrastructure
