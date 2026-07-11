# RecTrac Purchase Import

Attaches RecTrac PT-package purchases onto client profiles in Supabase. Reads the
**PARD Training Packages Report** CSV (one row per purchase) that Power Automate
already drops daily into a synced OneDrive folder, and lands each purchase as a
package on the matching client.

## Posture: AUTO-WRITE (see ADR-0008)

Writes to Supabase via REST with the key in `SUPABASE_ANON_KEY` (RLS disabled).
Per row:

- Map `pt_package` -> canonical type (`PRODUCT_TYPE_MAP` exact match + a pattern
  fallback that handles Baca zero-padding `03` and the `1st Time` intro).
  Unmappable -> review.
- Match a client by email, else phone (unique).
- Matched -> append the package to `client.packages` (PATCH), stamp
  `last_package_added_at`.
- No match -> CREATE the client from the row (name/email/phone/dob/location),
  carrying the package. This backfills buyers who never did an intake.
- `Purchase` -> `source: rectrac_import`; `Renewal` -> `rectrac_reup`.
  `validDays` is derived from the CSV's start/expiry.

**Idempotent** by `(type, purchaseDate)` per client, so re-running the same daily
or YTD report never double-adds a package.

### Package catalog mirror

`PACKAGE_CATALOG` in the script mirrors the app's `PT_PACKAGES_BY_FACILITY`
(RoundRock_Fitness_Tracker.html). **Keep them in sync** - if the app catalog
gains or repricing a package, update the script too. v4.45 added `CMRC-Pairs-8`
and `CMRC-Pairs-12` to both. Pairs come through as one report row per partner, so
each becomes its own client+package; the app's Pairs-to-Confirm flow links them.

## Usage

    set SUPABASE_ANON_KEY=<the app's designed-public anon key>
    python purchase_import.py --watch-dir "C:\Users\rmorrow\OneDrive - City of Round Rock\Docs\RecTrac Personal Training Imports"

`--dry-run` previews the plan and writes nothing - always rehearse a batch dry
first, especially any large/YTD backfill (it creates a client per unmatched
buyer). Stdlib only. Feed the CSV **Training Packages Report** (it has email +
phone); the YTD PDF has neither and cannot be the feed.

## Schedule

Runs live via Windows Task Scheduler **"RRPR Purchase Import"** at 8am weekdays
(after the ~7am report drop, so it processes same-day), using
`run_purchase_import.cmd` (gitignored). Use the **real** Python interpreter, not
the Store shim. Log: `purchase_import.task.log` (gitignored).

## Security

Auto-writes financial/package data and auto-creates client rows in prod through a
public anon key. **RLS is urgent** (ADR-0008). Rotate any key pasted into a chat
during setup; the scheduled task uses the designed-public anon key. Sibling to
the read-only `rectrac-import/rectrac_import.py` (client-roster import, still
emit-and-review).
