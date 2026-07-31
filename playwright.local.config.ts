import { defineConfig, devices } from '@playwright/test';

/**
 * Local write-test config (persist-correctness suite).
 *
 * Unlike playwright.config.ts (read-only smoke against the live deployment),
 * this config serves the repo's own HTML with STORAGE_MODE flipped to
 * 'localStorage' via scripts/serve-local.js. Tests here MAY create, edit,
 * and delete data freely - nothing leaves the browser context.
 *
 * Run: npm run test:local
 */
const PORT = Number(process.env.LOCAL_PORT || 4173);

export default defineConfig({
  testDir: './tests-local',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 2,
  reporter: 'list',
  timeout: 45_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: 'http://localhost:' + PORT,
    headless: true,
    actionTimeout: 10_000,
    navigationTimeout: 15_000,
    trace: 'on-first-retry',
  },
  webServer: {
    command: 'node scripts/serve-local.js',
    port: PORT,
    reuseExistingServer: !process.env.CI,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
