import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests",
  testMatch: "*.spec.ts",
  fullyParallel: false,
  use: {
    baseURL: "http://localhost:4175",
    viewport: { width: 1440, height: 1100 },
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node server.ts --dev --port 4175",
    url: "http://localhost:4175/tests/harness.html",
    reuseExistingServer: false,
  },
});
