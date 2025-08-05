import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 5 * 60 * 1000, // 5 minutes per test
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: 'list',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { 
        ...devices['Desktop Chrome'],
        // Don't run headless by default for debugging
        headless: process.env.PLAYWRIGHT_HEADLESS === '1',
      },
    },
  ],

  webServer: {
    command: 'echo "Using existing Docker containers"',
    port: 3000,
    reuseExistingServer: true,
  },
});