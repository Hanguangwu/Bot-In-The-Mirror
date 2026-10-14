-- M2b Lane-A 远端 D1 schema（docs/M2b-实施说明.md §4 逐字实现）
-- 时间列一律 UTC ISO8601 文本。
-- 来源规则（B1）：entities.version/updated_at/deleted_at 与 change_log.version/updated_at
--   一律取自 payload 快照；entities.device_id / change_log.device_id 一律取自 token。

CREATE TABLE users (
  id TEXT PRIMARY KEY,            -- 复用客户端匿名 userId
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,            -- 服务端生成
  owner_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workspace_members (
  workspace_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'owner',   -- 预留
  created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,            -- 客户端 deviceId
  user_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  last_sync_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE auth_tokens (
  token_hash TEXT PRIMARY KEY,    -- SHA-256(token) 十六进制；不存明文
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);

-- 一行 = 某工作区内某实体当前最新快照
CREATE TABLE entities (
  workspace_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,      -- conversation|message|task|ai_plan|calendar_entry|project
  entity_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,        -- 产生此版本的设备（用于诊断）
  version INTEGER NOT NULL,       -- 取自 payload（§5.4）
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,       -- 取自 payload
  deleted_at TEXT,                -- 取自 payload；NULL 表示未删
  payload TEXT NOT NULL,          -- 实体快照 JSON
  PRIMARY KEY (workspace_id, entity_type, entity_id)
);

-- 变更日志：增量拉取游标
CREATE TABLE change_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- 单调游标
  workspace_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  version INTEGER NOT NULL,       -- 取自 payload
  kind TEXT NOT NULL,             -- create|update|delete
  device_id TEXT NOT NULL,        -- 取自 token（§5.4）
  op_id TEXT NOT NULL,            -- 幂等键（客户端 SyncOperation.id）
  payload TEXT NOT NULL,          -- 该次变更后的实体快照
  updated_at TEXT NOT NULL,       -- 取自 payload
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_change_log_op ON change_log (workspace_id, op_id);
CREATE INDEX idx_change_log_cursor ON change_log (workspace_id, seq);
CREATE INDEX idx_entities_type ON entities (workspace_id, entity_type);
