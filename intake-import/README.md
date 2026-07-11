# Intake Packet Import

Processes the JSON files Power Automate drops in the OneDrive intake dropbox
(one per Microsoft Forms Pre-Assessment response) into Supabase.

## Posture: AUTO-WRITE (changed 2026-07-10, see ADR-0008)

This script **writes to Supabase** via the REST API with the key in
`SUPABASE_ANON_KEY` (RLS is disabled, so the anon key authorizes the write). It
was previously read-only / emit-SQL; that posture is retired.

Per validated response it provisions **both**:

- a **client** row carrying `intake_paperwork` (intake-v2 JSONB, rendered in
  ClientDetail since v4.43), and
- a linked **`waiting` consult-queue lead** (`source ms_forms`), wiring
  `client.from_queue_id = lead.id` so a trainer picks it up and reads the full
  packet in LeadDetailModal (v4.44).

Dedup: an existing client (unique email, else phone) gets its paperwork PATCHed
and a lead only if none is open; a new person is created with a lead (reusing an
open lead if one matches); junk / unreadable / not-intake-v2 / ambiguous lands in
`review/` plus `review_YYYY-MM-DD.csv`. The script never guesses. A partial-write
failure leaves the file in place so the next run self-heals via the dedup rules.

## Usage

    set SUPABASE_ANON_KEY=<the app's designed-public anon key>
    python intake_import.py --watch-dir "C:\Users\rmorrow\OneDrive - City of Round Rock\Docs\intake_dropbox"

`--dry-run` previews the plan and writes nothing (always rehearse a batch dry
first). Stdlib only.

## Schedule

Runs live via Windows Task Scheduler **"RRPR Intake Import"** at 5am daily, using
`run_intake_import.cmd` (gitignored; holds the anon key + machine paths). Use the
**real** Python interpreter, not the Store `WindowsApps` shim. Log:
`intake_import.task.log` (gitignored).

## PHI / security

`intake_paperwork` contains health-screening answers (PHI). The intake JSON, the
dropbox, and every write carry it. Keep the dropbox inside the City OneDrive
tenant; do not relocate to a broadly-shared folder. **RLS on `clients`/`leads` is
now urgent** (per ADR-0008 and CLAUDE.md Security posture) - an unattended script
writes PHI to prod through a public anon key. Rotate any key pasted into a chat
during setup; the scheduled task uses the designed-public anon key.
