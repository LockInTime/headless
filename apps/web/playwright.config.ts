import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  use: {
    baseURL: "http://127.0.0.1:4173",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "pnpm exec next start -H 127.0.0.1 -p 4173",
    url: "http://127.0.0.1:4173/docs/commands",
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
