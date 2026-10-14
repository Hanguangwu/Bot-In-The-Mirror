/// <reference path="../node_modules/@cloudflare/vitest-pool-workers/types/cloudflare-test.d.ts" />
import type { D1Migration } from "cloudflare:test";

/**
 * 本地 D1 绑定与测试迁移的类型声明（vitest-pool-workers 从 `Cloudflare.Env`
 * 取 `env` 类型）。
 */
declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export {};
