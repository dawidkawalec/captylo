import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // pglite boots a WASM Postgres per test file; give it room on a cold start.
    testTimeout: 20_000,
    hookTimeout: 30_000,
  },
});
