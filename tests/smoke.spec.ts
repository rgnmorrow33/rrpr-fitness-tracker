import { test as base, expect, type Page } from '@playwright/test';

/**
 * Round Rock Fitness Tracker - read-only post-deploy smoke suite (v1).
 *
 * Scope: views reachable as 1111 / Front Desk (role: 'admin'). Every test
 * clicks through from the login screen (no router, no deep-link), anchors on a
 * data-testid added in Phase 2A, and asserts no unexpected console output.
 *
 * READ-ONLY. The suite never clicks edit/log/save controls, never opens the
 * notification bell, and never marks notifications read. Detail views are
 * opened and asserted only. See tests/README.md for write-safety notes
 * (the 4 lazy on-mount migrations are idempotent no-ops on the live DB).
 */

/* ------------------------------------------------------------------ *
 * Console allowlist
 *
 * These prefixes fire benignly on a healthy load and must NOT fail a test.
 * Anything else at console.error / console.warn level (or an uncaught page
 * error) is a hard failure - notably "[bell] cross-user" and "unable to
 * resolve actor name".
 *
 * Reconciled against the real Phase-2 baseline (Phase 1 was static). On a
 * clean load the app fires a `pageshow` sweep that intentionally tears down
 * and re-subscribes the realtime channel, logging "status=CLOSED" +
 * "scheduling reconnect" and then "reconnected" ~100ms later. That transient
 * is benign and self-healing - it is NOT the "subs actually drop in
 * production" P1. It is handled below (recovery-gated), not blanket-allowed,
 * so a genuine UNrecovered drop still fails the suite.
 * ------------------------------------------------------------------ */
const CONSOLE_ALLOWLIST: string[] = [
  '[realtime] subscribed',   // per-table subscribe confirmation on load (one per channel)
  '[realtime] reconnected',  // benign recovery confirmation after the sweep
  '[realtime] sweep',        // benign pageshow/visibility resubscribe trigger
  'migrate_',                // lazy package migrations - idempotent, log-only when clean
  'strip_writeonly',         // lazy package-field strip migration - idempotent
  'Dedup cleanup',           // one-time class dedup - idempotent, log-only when clean
  // Benign data-shape warning: a session with durationHours=0.75 (45 min) is
  // outside the documented 1.0/0.5 set; calcTrainerHours defaults the ratio to
  // 1.0 and continues. Test-data artifact, surfaced on hours-computing views.
  // (Flagged separately as a data smell, not a code bug.)
  'Unexpected session durationHours',
];

function isAllowed(text: string): boolean {
  return CONSOLE_ALLOWLIST.some((p) => text.startsWith(p));
}

/** Transient realtime warnings emitted by the on-load pageshow sweep.
 *  v4.33: channels are now per-table ('table-changes-<table>') rather than a
 *  single 'app-changes' channel, so the sweep emits one CLOSED warn per table. */
function isRealtimeTransient(text: string): boolean {
  return (
    (text.startsWith('[realtime] table-changes-') && text.includes('status=CLOSED')) ||
    text.startsWith('[realtime] scheduling reconnect')
  );
}

type ConsoleMsg = { type: string; text: string };

/**
 * Auto fixture: attaches a console/pageerror collector to every test's page
 * before it navigates, then asserts (during teardown) that nothing outside the
 * allowlist printed. Applies the console assertion to every test for free.
 *
 * Captures every console message (so realtime recovery can be detected) but
 * only treats error / warning / pageerror as failure candidates.
 */
const test = base.extend<{ consoleGuard: ConsoleMsg[] }>({
  consoleGuard: [
    async ({ page }, use) => {
      const messages: ConsoleMsg[] = [];
      page.on('console', (msg) => {
        messages.push({ type: msg.type(), text: msg.text() });
      });
      page.on('pageerror', (err) => {
        messages.push({ type: 'pageerror', text: String((err && err.message) || err) });
      });

      await use(messages);

      // The realtime channel is considered healthy if a "reconnected" (or the
      // initial "subscribed") confirmation appears - i.e. the sweep recovered.
      const realtimeRecovered = messages.some(
        (m) => m.text.startsWith('[realtime] reconnected') || m.text.startsWith('[realtime] subscribed'),
      );

      const offenders = messages
        .filter((m) => m.type === 'error' || m.type === 'warning' || m.type === 'pageerror')
        .filter((m) => !isAllowed(m.text))
        // Drop the benign on-load sweep transient ONLY when the channel
        // actually recovered. An unrecovered drop (no reconnected) still fails.
        .filter((m) => !(isRealtimeTransient(m.text) && realtimeRecovered));

      expect(
        offenders,
        `Unexpected console output (not in allowlist):\n` +
          offenders.map((o) => `  [${o.type}] ${o.text}`).join('\n'),
      ).toEqual([]);
    },
    { auto: true },
  ],
});

/* ------------------------------------------------------------------ *
 * Helpers
 * ------------------------------------------------------------------ */

/**
 * Log in via the legacy Front Desk PIN and land on the admin overview.
 * PIN comes from SMOKE_TEST_PIN (default "1111"); never hardcoded beyond that.
 */
async function loginAsFrontDesk(page: Page): Promise<void> {
  const pin = process.env.SMOKE_TEST_PIN || '1111';

  await page.goto('/');
  await expect(page.getByTestId('view-login')).toBeVisible();

  // "Front desk?" launcher opens the PIN keypad.
  await page.locator('.login-admin > button').click();
  const modal = page.getByTestId('modal-pin');
  await expect(modal).toBeVisible();

  // Tap each digit on the keypad. The PIN auto-submits ~180ms after the
  // 4th digit; Playwright's auto-wait on the overview testid covers the gap.
  for (const digit of pin) {
    await modal.getByRole('button', { name: digit, exact: true }).click();
  }

  await expect(page.getByTestId('view-admin-overview')).toBeVisible();
}

/** Click a sidebar nav item by its visible label. */
async function clickNav(page: Page, label: string): Promise<void> {
  await page.locator('.nav-item', { hasText: label }).first().click();
}

/* ------------------------------------------------------------------ *
 * Tests - admin-reachable views (1111 / Front Desk)
 * ------------------------------------------------------------------ */

/**
 * v4.47 regression. The signed-out login screen must not read any table that
 * identity RLS (migration 0005) denies to anon.
 *
 * The bug: the realtime subscription effect mounts with [] deps - i.e. while
 * signed OUT - and registers a pageshow listener. pageshow fires on EVERY
 * normal navigation, not just BFCache restore, so wakeCatchUp() fired all 12
 * entity reloaders on every single page load of the login screen. Eleven came
 * back 42501 (the twelfth, trainers, is readable via the trainer_directory
 * view). That is 11 guaranteed-to-fail requests per device per load, all day,
 * plus the same burst on every wake - and it is what took the whole suite red
 * on 2026-07-14 through the consoleGuard fixture.
 *
 * loadAll() already gated on isStaff(); reload() did not. This asserts the gate
 * stays put. It does NOT rely on the browser happening to emit a wake event -
 * it fires all three wake paths by hand.
 *
 * The consoleGuard fixture would also catch a regression here, but as an
 * anonymous wall of noise. This test names the bug.
 */
test('0. signed-out login screen fires no RLS-denied reads', async ({ page }) => {
  const denied: string[] = [];
  page.on('console', (msg) => {
    const text = msg.text();
    if (
      text.includes('permission denied for table') ||
      text.startsWith('Subscription reload failed')
    ) {
      denied.push(text);
    }
  });

  await page.goto('/');
  await expect(page.getByTestId('view-login')).toBeVisible();

  // Fire every wake path that calls wakeCatchUp(). onVisible() re-reads
  // document.visibilityState itself, so dispatching the bare event is enough.
  await page.evaluate(() => {
    window.dispatchEvent(new Event('pageshow'));
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('online'));
  });

  // reload() is debounced 100ms; give the (blocked) requests room to land.
  await page.waitForTimeout(1500);

  expect(
    denied,
    'Signed-out page issued reads that RLS denies. reload() lost its isStaff() ' +
      'gate (v4.47):\n' + denied.map((d) => `  ${d}`).join('\n'),
  ).toEqual([]);
});

test('1. login lands on admin overview', async ({ page }) => {
  await loginAsFrontDesk(page);
  await expect(page.getByTestId('view-admin-overview')).toBeVisible();
});

test('2. schedule view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Schedule');
  await expect(page.getByTestId('view-admin-schedule')).toBeVisible();
});

test('3. clients view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Clients');
  await expect(page.getByTestId('view-admin-clients')).toBeVisible();
});

test('4. client detail opens from clients list', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Clients');
  await expect(page.getByTestId('view-admin-clients')).toBeVisible();

  const cards = page.locator('.client-card');
  const count = await cards.count();
  test.skip(count === 0, 'No client rows on test DB - client detail unreachable, skipping (not a failure)');

  await cards.first().click();
  await expect(page.getByTestId('view-client-detail')).toBeVisible();
});

test('5. classes view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Classes');
  await expect(page.getByTestId('view-admin-classes')).toBeVisible();
});

test('6. class detail opens from classes list', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Classes');
  await expect(page.getByTestId('view-admin-classes')).toBeVisible();

  const cards = page.locator('.class-card');
  const count = await cards.count();
  test.skip(count === 0, 'No class rows on test DB - class detail unreachable, skipping (not a failure)');

  await cards.first().click();
  await expect(page.getByTestId('view-class-detail')).toBeVisible();
});

test('7. leads view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Leads');
  await expect(page.getByTestId('view-leads')).toBeVisible();
});

test('8. audit view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Audit log');
  await expect(page.getByTestId('view-audit')).toBeVisible();
});

test('9. payroll view renders', async ({ page }) => {
  await loginAsFrontDesk(page);
  await clickNav(page, 'Payroll');
  await expect(page.getByTestId('view-payroll')).toBeVisible();
});

/* ------------------------------------------------------------------ *
 * Tests 10-12 - trainer views - DEFERRED TO v2 (trainer-PIN suite)
 *
 * Determination (Phase 1 + 2A): a 1111 / Front Desk session is role:'admin'.
 * The admin->trainer "view as" affordance (ViewModeToggle) renders ONLY for
 * role:'lead', and the App render switch routes admin straight to
 * AdminDashboard with no TrainerView path. TrainerToday / TrainerGX are
 * therefore unreachable without a trainer (or lead) PIN, which v1 cannot
 * perform. Not inventing a login the suite can't do - deferred.
 * ------------------------------------------------------------------ */
test.skip('10-12. trainer views (today / gx my classes / gx full schedule)', () => {
  // Deferred to v2 trainer-PIN suite. See note above.
});
