# RecTrac CSV Import Processor

Watches a drop folder for RecTrac CSV exports, validates and maps them to the
13 Supabase client fields, and sorts every row into one of three lanes. **It
does not write to Supabase.** The actual database insert stays in your lane.

## The no-write posture (why this exists)

By design this script stops short of the database. It parses, validates,
auto-maps, backfills trainers, and emits clean files. You review those files
and run the actual insert yourself in the Supabase SQL editor, same as all
other SQL.

Do not promote this to auto-write until all three are true:
1. IT has scoped which key the job uses and where it lives.
2. The 13 flat fields are validated against a real `clients` JSONB row
   (packages/sessions/audit_log are nested; a naive flat insert can create
   records the app can't render).
3. Cross-batch dedup is checked against the LIVE database, not just the local
   ledger.

## Three output lanes

Every source row lands in exactly one place:

| File | Meaning | What you do with it |
|---|---|---|
| `ready_to_import_YYYY-MM-DD.csv` | Net-new solo PT clients | INSERT as new client rows |
| `returning_clients_YYYY-MM-DD.csv` | Renewals + known names + same-day repeats | PACKAGE-APPEND to the existing client, NOT a new insert |
| `pairs_for_review_YYYY-MM-DD.csv` | Pairs/Group packages | Link participants in-app via the pairs-to-confirm queue; raw Pass Code preserved, dates NOT normalized |
| `flagged_for_review_YYYY-MM-DD.csv` | Broken rows / unknown Pass Codes | Fix by hand; carries `flag_reason` |

`match_note` values in the returning lane: `rectrac_renewal` (RecTrac's
TransactionType said Renewal), `package_append_candidate` (known from a prior
day/seed), `same_day_additional_purchase` (a second+ row for the same name in
today's file), or a combination.

A row routes to `returning_clients` if ANY of: RecTrac marks it `Renewal`, the
name is in the ledger, or the name already appeared earlier in today's file.
RecTrac's `Renewal` flag is authoritative and works even with an empty ledger.

A returning client is matched on **name only** (`first_name|last_name`,
lowercased). The package on the row is ignored for matching, because RecTrac
tracks renewals per-activity and we don't, a known person showing up with any
package is a renewal. Returning rows are package-append candidates because the
flat import cannot tell insert-new from append-to-existing on its own.

The RecTrac export is a **daily purchases report**: one row per package
purchased that day, for new buyers and renewals alike. Two consequences:

- A person can legitimately appear twice in one file (e.g. buying two
  `CMRC-PT-1` packages same day because there's no 2-session package). This is
  NOT an error. The first occurrence routes normally (insert if new, append if
  known); each later same-day occurrence routes to `returning_clients` marked
  `same_day_additional_purchase`. For a brand-new person buying twice same day,
  row 1 creates the client and row 2 is an append candidate, so the client is
  never created twice.
- Re-processing the same daily file is NOT idempotent: every row flips to
  "returning" on a second pass. The archive step prevents this in normal use.
  Don't re-run against an un-archived folder.

Hard flags (missing both names, non-numeric sessions) always win over the
append lane. A broken row that also matches a known client goes to
`flagged_for_review` with `also_matches_known_client` appended to the reason,
so it's never silently treated as a clean renewal.

## Trainer backfill

RecTrac doesn't carry the assigned trainer. The script backfills it from a
local ledger, never from the database, and never silently:

| CSV trainer field | Ledger has prior trainer? | Result | `trainer_source` |
|---|---|---|---|
| has a value | (ignored) | keep CSV value | `csv` |
| empty | yes | fill from ledger | `ledger_backfill` |
| empty | no | leave empty | `unassigned` |

The ledger only records a trainer from a CSV-carried value. A backfilled
(guessed) value never becomes the ledger's new truth. Review any
`ledger_backfill` rows before import; the ledger learns from imports, not from
in-app reassignments, so it can lag a client who switched trainers in the app.

## Usage

One-time, seed the ledger from a Supabase export you run yourself
(`first_name,last_name,assigned_trainer`):

```
python rectrac_import.py --watch-dir "C:\path\to\dropfolder" --seed-ledger seed_clients.csv
```

Each run (schedule via Task Scheduler / Power Automate, one-shot, not a daemon):

```
python rectrac_import.py --watch-dir "C:\path\to\dropfolder"
```

Dry run (parse and report only, writes nothing, no archive, no ledger change):

```
python rectrac_import.py --watch-dir "C:\path\to\dropfolder" --dry-run
```

## Package translation

RecTrac Pass Codes are translated to your locked package names from a fixed
table (built from the RecTrac training setup export). Solo PT packages map to
`CMRC-PT-N` / `Baca-PT-N` / `Baca-1stTime-3`, and the session count is derived
from the Pass Code (you don't need to send a sessions column).

Pairs and Group packages (any Pass Code containing "pairs" or "group") are NOT
translated. They route to `pairs_for_review` untouched, because a pairs/group
purchase is a multi-person relationship the flat import can't reconstruct (it
would collide with the participant_ids model). You link participants in-app.

An unknown Pass Code (not in the table, not pairs/group) routes to
`flagged_for_review` with reason `unknown_pass_code`. The script never guesses a
translation. When RecTrac adds a new package type, add it to
`PACKAGE_TRANSLATION` in the script.

Dates (`date_of_birth`, `package_start`, `package_expiry`) are normalized to ISO
`YYYY-MM-DD` for solo rows. A date that can't be parsed flags the row rather
than being silently mangled. (Pairs-lane rows keep their original date format.)

## Recommended RecTrac export columns

The daily report should have these headers (Selisa's export already matches):
`first_name, last_name, email, phone, date_of_birth, pt_package,
package_start, package_expiry, transaction_type`

- `pt_package` is the raw RecTrac Pass Code text; the script translates it.
- `transaction_type` must be `Purchase` or `Renewal`; Renewal is authoritative
  for returning-client routing.
- `assigned_trainer` is intentionally absent; the script backfills from the
  ledger.

## Per run, the script also

- Skips the WHOLE file (logs a warning, no partial import) if `first_name` or
  `last_name` can't be mapped.
- Archives each processed source CSV to `archive/`.
- Appends a line to `import_manifest.log` so split files stay traceable.
- Ignores its own output files and the archive folder on the next run.

## Standard library only

No pip install. Runs on any Python 3 the municipal machine has.
