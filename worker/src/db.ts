/**
 * D1 访问封装（§8）：仅使用 `prepare().bind().first()/all()/run()/batch()`。
 *
 * 强约束（B1，§4）：
 * - `entities.version/updated_at/deleted_at` 与 `change_log.version/updated_at`
 *   一律取自 payload 快照；
 * - `entities.device_id` / `change_log.device_id` 一律取自 token（不取信封/payload）。
 * - 不记录 token 明文与完整 payload。
 */

/** Worker 绑定（wrangler.toml）。 */
export interface Env {
  DB: D1Database;
}

/** `entities` 行。 */
export interface EntityRow {
  workspace_id: string;
  entity_type: string;
  entity_id: string;
  user_id: string;
  device_id: string;
  version: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  payload: string;
}

/** `change_log` 扫描行（pull 用）。 */
export interface ChangeLogRow {
  seq: number;
  entity_type: string;
  entity_id: string;
  version: number;
  kind: string;
  device_id: string;
  payload: string;
  updated_at: string;
}

/** 服务端时钟：UTC ISO8601（带 Z）。 */
export function nowIso(): string {
  return new Date().toISOString();
}

/** 读某工作区内某实体当前快照行；不存在返回 null。 */
export function getEntity(
  db: D1Database,
  workspaceId: string,
  entityType: string,
  entityId: string,
): Promise<EntityRow | null> {
  return db
    .prepare(
      `SELECT workspace_id, entity_type, entity_id, user_id, device_id, version,
              created_at, updated_at, deleted_at, payload
         FROM entities
        WHERE workspace_id = ? AND entity_type = ? AND entity_id = ?`,
    )
    .bind(workspaceId, entityType, entityId)
    .first<EntityRow>();
}

/** 幂等检查：该工作区内 op_id 是否已生效。 */
export async function hasChangeLogOp(
  db: D1Database,
  workspaceId: string,
  opId: string,
): Promise<boolean> {
  const row = await db
    .prepare(
      "SELECT op_id FROM change_log WHERE workspace_id = ? AND op_id = ? LIMIT 1",
    )
    .bind(workspaceId, opId)
    .first<{ op_id: string }>();
  return row !== null;
}

/** 已接受变更的写入入参；字段来源见文件头注释。 */
export interface ApplyEntityChangeInput {
  workspaceId: string;
  entityType: string;
  entityId: string;
  /** 取自 token（== payload.userId，已校验）。 */
  userId: string;
  /** 取自 token。 */
  deviceId: string;
  /** 取自 payload。 */
  version: number;
  createdAt: string;
  /** 取自 payload。 */
  updatedAt: string;
  /** 取自 payload；null 表示未删。 */
  deletedAt: string | null;
  kind: string;
  opId: string;
  /** 实体快照 JSON（已序列化，不额外解释领域字段）。 */
  payloadJson: string;
}

/**
 * 原子写入实体快照 + 变更日志（`db.batch()` 单次往返，§5.2）。
 * 两条语句在同一事务内执行，任一失败整体回滚。
 */
export async function applyEntityChange(
  db: D1Database,
  change: ApplyEntityChangeInput,
): Promise<void> {
  const upsertEntity = db
    .prepare(
      `INSERT INTO entities
         (workspace_id, entity_type, entity_id, user_id, device_id, version,
          created_at, updated_at, deleted_at, payload)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(workspace_id, entity_type, entity_id) DO UPDATE SET
         user_id = excluded.user_id,
         device_id = excluded.device_id,
         version = excluded.version,
         created_at = excluded.created_at,
         updated_at = excluded.updated_at,
         deleted_at = excluded.deleted_at,
         payload = excluded.payload`,
    )
    .bind(
      change.workspaceId,
      change.entityType,
      change.entityId,
      change.userId,
      change.deviceId,
      change.version,
      change.createdAt,
      change.updatedAt,
      change.deletedAt,
      change.payloadJson,
    );

  const insertChangeLog = db
    .prepare(
      `INSERT INTO change_log
         (workspace_id, entity_type, entity_id, version, kind, device_id, op_id,
          payload, updated_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      change.workspaceId,
      change.entityType,
      change.entityId,
      change.version,
      change.kind,
      change.deviceId,
      change.opId,
      change.payloadJson,
      change.updatedAt,
      nowIso(),
    );

  await db.batch([upsertEntity, insertChangeLog]);
}

/**
 * 增量扫描（B2）：`seq > cursor ORDER BY seq ASC LIMIT limit`。
 * **全量扫描**——设备过滤不参与游标（剔除在 handler 组装阶段）。
 */
export function scanChangeLog(
  db: D1Database,
  workspaceId: string,
  cursor: number,
  limit: number,
): Promise<D1Result<ChangeLogRow>> {
  return db
    .prepare(
      `SELECT seq, entity_type, entity_id, version, kind, device_id, payload, updated_at
         FROM change_log
        WHERE workspace_id = ? AND seq > ?
        ORDER BY seq ASC
        LIMIT ?`,
    )
    .bind(workspaceId, cursor, limit)
    .all<ChangeLogRow>();
}
