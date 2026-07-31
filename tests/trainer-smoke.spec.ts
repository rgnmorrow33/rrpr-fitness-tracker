import { test as base, expect, type Page } from '@playwright/test';

/**
 * Round Rock Fitness Tracker - trainer/GX view smoke suite (v2 gap-fill).
 *
 * Covers the views deferred by the v1 admin suite (smoke.spec.ts tests 10-12):
 * TrainerToday and the two TrainerGX surfaces. These are unreachable from a
 * 1111 / Front Desk (role:'admin') session - they need a per-trainer PIN login,
 * which sets trainer_id and role:'trainer'. Read-only: taps name tile, enters
 * PIN, lands on Today, switches to GX, opens Full schedule. No log/sign/save,
 * no bell open, no "mark read".
 *
 * Credentials come from env (never hardcoded - trainer PINs are real):
 *   SMOKE_TRAINER_NAME  exact name on the login tile (e.g. "Carlos Vega")
 *   SMOKE_TRAINER_PIN   that trainer's 4-digit PIN
 * If either is unset the whole file skips (same spirit as the 1111 default in
 * the admin suite, but there is no safe default PIN for a real trainer).
 */

const TRAINER_NAME = process.env.SMOKE_TRAINER_NAME || '';
const TRAINER_PIN = process.env.SMOKE_TRAINER_PIN || '';

/* Reuse the admin suite's console allowlist verbatim so trainer loads are held
 * to the same bar. A per-trainer login additionally mounts the notification
 * bell; "[bell] cross-user" and "unable to resolve actor name" remain hard
 * failures (they are NOT allowlisted), which is exactly what we want to catch. */
const CONSOLE_ALLOWLIST: string[] = [
  '[realtime] subscribed',
  '[realtime] reconnected',
  '[realtime] sweep',
  'migrate_',
  'strip_writeonly',
  'Dedup cleanup',
  'Unexpected session durationHours',
];

function isAllowed(text: string): boolean {
  return CONSOLE_ALLOWLIST.some((p) => text.startsWith(p));
}

function isRealtimeTransient(text: string): boolean {
  return (
    (text.startsWith('[realtime] table-changes-') && text.includes('status=CLOSED')) ||
    text.startsWith('[realtime] scheduling reconnect')
  );
}

type ConsoleMsg = { type: string; text: string };

const test = base.extend<{ consoleGuard: ConsoleMsg[] }>({
  consoleGuard: [
    async ({ page }, use) => {
      const messages: ConsoleMsg[] = [];
      page.on('console', (msg) => messages.push({ type: msg.type(), text: msg.text() }));
      page.on('pageerror', (err) =>
        messages.push({ type: 'pageerror', text: String((err && err.message) || err) }),
      );

      await use(messages);

      const realtimeRecovered = messages.some(
        (m) =>
          m.text.startsWith('[realtime] reconnected') ||
          m.text.startsWith('[realtime] subscribed'),
      );

      const offenders = messages
        .filter((m) => m.type === 'error' || m.type === 'warning' || m.type === 'pageerror')
        .filter((m) => !isAllowed(m.text))
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

test.skip(
  !TRAINER_NAME || !TRAINER_PIN,
  'SMOKE_TRAINER_NAME / SMOKE_TRAINER_PIN not set - trainer suite needs a real per-trainer PIN',
);

/** Log in via a per-trainer name tile + PIN and land on TrainerToday.
 *
 * A plain trainer (role:'trainer') lands on Today directly. A lead
 * (role:'lead', e.g. Carlos Vega) lands on the lead dashboard instead and
 * exposes a Lead/Trainer view toggle (ViewModeToggle renders only for leads);
 * we flip it to 'Trainer' to reach the trainer surfaces. Handle both. */
async function loginAsTrainer(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.getByTestId('view-login')).toBeVisible();

  await page.locator('.trainer-tile', { hasText: TRAINER_NAME }).first().click();
  const modal = page.getByTestId('modal-pin');
  await expect(modal).toBeVisible();
  for (const digit of TRAINER_PIN) {
    await modal.getByRole('button', { name: digit, exact: true }).click();
  }

  const todayView = page.getByTestId('view-trainer-today');
  const trainerToggle = page.getByRole('button', { name: 'Trainer', exact: true });
  // Login succeeded once either Today (trainer) or the view toggle (lead) shows.
  await expect(todayView.or(trainerToggle).first()).toBeVisible();
  if (!(await todayView.isVisible())) {
    await trainerToggle.click();
  }
  await expect(todayView).toBeVisible();
}

/** Click a trainer top-bar tab by visible label. */
async function clickTab(page: Page, label: string): Promise<void> {
  await page.locator('.trainer-tabs .tab', { hasText: label }).first().click();
}

test('10. trainer login lands on Today', async ({ page }) => {
  await loginAsTrainer(page);
  await expect(page.getByTestId('view-trainer-today')).toBeVisible();
});

test('11. GX tab renders My Classes', async ({ page }) => {
  await loginAsTrainer(page);
  await clickTab(page, 'GX');
  await expect(page.getByTestId('view-gx-my-classes')).toBeVisible();
});

test('12. GX Full schedule opens', async ({ page }) => {
  await loginAsTrainer(page);
  await clickTab(page, 'GX');
  await expect(page.getByTestId('view-gx-my-classes')).toBeVisible();
  await page.getByRole('button', { name: 'Full schedule' }).click();
  await expect(page.getByTestId('view-gx-full-schedule')).toBeVisible();
});
