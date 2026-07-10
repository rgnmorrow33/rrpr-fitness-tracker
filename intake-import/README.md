# Intake Packet Import

Processes the JSON files Power Automate drops in the OneDrive intake dropbox
(one per Microsoft Forms Pre-Assessment response) into a reviewed SQL file
that sets `clients.intake_paperwork` (intake-v2, rendered in ClientDetail
since v4.43).

Same posture as `rectrac-import`: NO writes to Supabase. Matching is a
read-only REST GET; the emitted `intake_updates_YYYY-MM-DD.sql` gets reviewed
and run by Reagan in the Supabase SQL editor. Non-matches land in `review/`
plus `review_YYYY-MM-DD.csv` - the script never guesses.

    set SUPABASE_ANON_KEY=<the app's designed-public anon key>
    python intake_import.py --watch-dir "C:\Users\rmorrow\OneDrive - City of Round Rock\Docs\intake_dropbox"

`--dry-run` to preview. Stdlib only. Schedule via Task Scheduler alongside
the RecTrac job (same Python path caveat: real Python, not the Store shim).

PHI note: intake JSON and the SQL lane contain health-screening answers.
Keep the dropbox inside the City OneDrive tenant; do not relocate to a
broadly-shared folder. RLS on `clients` must be resolved before this
pipeline goes to auto-write. See CLAUDE.md Security posture.
