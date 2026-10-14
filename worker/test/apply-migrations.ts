import { applyD1Migrations, env } from "cloudflare:test";

// 每个测试文件在本地 D1 上应用 `migrations/`（§11.1-5）。
// vitest.config.ts 通过 readD1Migrations() 注入 TEST_MIGRATIONS 绑定。
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
