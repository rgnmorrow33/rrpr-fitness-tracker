# Smoke tests

Read-only post-deploy smoke suite for the Round Rock Fitness Tracker. It loads
the live deployed app, logs in as Front Desk, clicks through the
admin-reachable views, and asserts each one renders with no unexpected console
output. It does **not** build the app (single-file HTML, no build step) - it
only exercises a running deployment.

## Run it

```bash
npm install
npx playwright install chromium   # one-time: download the browser
npm test                          # runs against the default test site
```

Headed (watch it click through):

```bash
npm run test:headed
```

## Environment variables

| Var              | Default                                  | Purpose                          |
| ---------------- | ---------------------------------------- | -------------------------------- |
| `SMOKE_URL`      | `https://pardfitnesstracker2.netlify.app` | Target deployment to test        |
| `SMOKE_TEST_PIN` | `1111`                                   | Front Desk PIN used to log in    |

```bash
SMOKE_URL=https://pardfitnesstracker.netlify.app SMOKE_TEST_PIN=1234 npm test
```

## What green means

All 9 admin views rendered (anchored on `data-testid`) **and** no console
error/warning fired outside the allowlist. A test fails if a target view does
not appear, or if any non-allowlisted `console.error` / `console.warn` /
uncaught page error occurs.

The console allowlist (in `smoke.spec.ts`) covers benign on-load chatter:
`[realtime] subscribed`, `migrate_*`, `strip_writeonly*`, `Dedup cleanup`.
Hard failures to watch for: `[bell] cross-user`, `[realtime] ... status=`,
`scheduling reconnect`, `unable to resolve actor name` - these are real bugs,
not test-tuning issues.

## Continuous smoke (GitHub Actions)

`.github/workflows/smoke.yml` runs this suite automatically on every push to
`main` and via the **Run workflow** button on the repo's Actions tab
(`workflow_dispatch`). It reports status only - it never deploys, pushes,
merges, or runs SQL.

**Deploy timing:** a push fires the Action and the Netlify build at the same
moment, so the Action waits before testing. It captures the live `ETag` before
its slow setup steps, then polls (up to ~4 min) until the served `ETag` changes
away from that value - i.e. the new build actually swapped in - before running.
If the push did not change `RoundRock_Fitness_Tracker.html` (e.g. a test- or
workflow-only commit) there is no content swap to wait for, so it just confirms
the site is up and runs. Caveat: Netlify's `ETag` is its own content hash and
is not derivable from the repo, so the workflow detects a content *change*, not
cryptographic proof that the exact pushed commit is serving. If the bounded
wait times out it proceeds anyway and logs a `::warning::` saying so.

**What a red check means:** a target view failed to render, or a
non-allowlisted console error/warning (or uncaught page error) fired on the live
site. The commit gets a ❌ status check; on a push failure the workflow also
posts a commit comment listing the failing view name(s).

**Where the report is:** open the failed run under the repo **Actions** tab and
download the **`playwright-report`** artifact (HTML report + `results.json`,
retained 14 days). Open `index.html` from it to see each step, screenshots, and
traces without re-running.

**Secret:** the workflow reads `SMOKE_TEST_PIN` from a GitHub Actions secret of
the same name (add it under Settings -> Secrets and variables -> Actions). If
the secret is unset the suite falls back to its default PIN, so the workflow
still runs before the secret is added. `SMOKE_URL` is a plain env default in the
workflow.

## Coverage (v1)

Reachable as 1111 / Front Desk (`role: 'admin'`):

1. Admin overview (post-login landing)
2. Schedule
3. Clients
4. Client detail (opens first client card; skips if the DB has zero clients)
5. Classes
6. Class detail (opens first class card; skips if the DB has zero classes)
7. Leads
8. Audit log
9. Payroll

Notification bell is **out of scope** in v1: it only renders for a per-user PIN
login (`trainer_id` present); the Front Desk session has `trainer_id: null`.

Trainer views (TrainerToday, TrainerGX) are **deferred to v2**: a 1111/admin
session cannot reach them. The admin->trainer view toggle renders only for
`role: 'lead'`, and admin routes straight to the dashboard. They need a trainer
or lead PIN, which v1 does not perform.

## Write-safety

The suite is read-only by design - no edit/log/save clicks, no bell, no
"mark read".

One caveat: the app runs four lazy data migrations on mount
(`migrate_package_type_prefix`, `strip_writeonly_pkg_fields`,
`migrate_package_participants`, and a one-time class dedup cleanup). On the
live, already-migrated DB these are idempotent no-ops that only log. **A first
run against a freshly restored / un-migrated database WILL write** (migration +
audit rows). That is acceptable and expected; it is documented here so it is not
a surprise.

## No router

The app has no URL/hash router. Tests must always start at the login screen and
navigate via clicks. A fresh Playwright context per test clears
`localStorage['rrpr_session_v1']` automatically, so the login screen shows
instead of auto-resuming a prior session.
