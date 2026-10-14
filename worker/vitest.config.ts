import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// 迁移目录：供测试在本地 D1 上应用（§11.1-5）。
const migrationsDir = path.join(
  fileURLToPath(new URL(".", import.meta.url)),
  "migrations",
);

export default defineConfig(async () => {
  const migrations = await readD1Migrations(migrationsDir);

  return {
    plugins: [
      // 单 worker：测试通过 SELF.fetch 走完整路由（本地 workerd + D1，不触网）。
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: { bindings: { TEST_MIGRATIONS: migrations } },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
