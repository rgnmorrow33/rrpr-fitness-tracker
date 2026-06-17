import { defineConfig, devices } from '@playwright/test';

/**
 * Read-only smoke suite config.
 *
 * Target URL comes from SMOKE_URL (default = test Netlify site). The suite
 * clicks through from the login screen every run - there is no router/deep-link
 * in the app - so each test starts from a fresh context (clean localStorage,
 * so the Login screen shows instead of auto-resuming a stored session).
 */
const SMOKE_URL = process.env.SMOKE_URL || 'https://pardfitnesstracker2.netlify.app';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  // Low concurrency on purpose: this hits a live deployment and cold-fetches
  // React + Supabase from CDNs per fresh context. Too many parallel cold loads
  // get throttled and time out at the login screen.
  workers: process.env.CI ? 2 : 3,
  reporter: process.env.CI
    ? [['list'], ['html', { open: 'never' }], ['json', { outputFile: 'results.json' }]]
    : 'list',
  timeout: 45_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: SMOKE_URL,
    headless: true,
    // The app loads React + Supabase from CDNs; give navigation room.
    actionTimeout: 10_000,
    navigationTimeout: 20_000,
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
