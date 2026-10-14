import '../../core/ids/ids.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/syncable_entity.dart';
import '../../domain/entities/task.dart';
import '../../domain/sync/entity_serializer.dart';

/// 由实体构造一条待同步操作（B1/B2 共享入队工厂，§7.3）。
///
/// 统一字段：`id` 用 [generateId] 生成、`userId`/`deviceId` 取调用方注入身份、
/// `payload` 为实体快照 `entity.toSyncJson()`、`status=pending`、`version=1`、
/// `createdAt=updatedAt=now`。
///
/// 本函数只构造对象，不落库；入队由调用方在**同一事务**内完成（§7.1）。
SyncOperation buildSyncOperation({
  required SyncableEntity entity,
  required String entityType,
  required SyncOperationKind kind,
  required String userId,
  required String deviceId,
  required DateTime now,
}) {
  return SyncOperation(
    id: generateId(),
    userId: userId,
    createdAt: now,
    updatedAt: now,
    version: 1,
    deviceId: deviceId,
    entityType: entityType,
    entityId: entity.id,
    kind: kind,
    payload: _payloadOf(entity),
    status: SyncOperationStatus.pending,
  );
}

/// 按运行时类型分发到对应的 `toSyncJson`。
///
/// `toSyncJson` 以扩展方法实现（`entity_serializer.dart`），无法在基类
/// [SyncableEntity] 上静态分派，故此处用模式匹配显式分发。
Map<String, Object?> _payloadOf(SyncableEntity entity) => switch (entity) {
      Conversation() => entity.toSyncJson(),
      Message() => entity.toSyncJson(),
      Task() => entity.toSyncJson(),
      AIPlan() => entity.toSyncJson(),
      CalendarEntry() => entity.toSyncJson(),
      Project() => entity.toSyncJson(),
      _ => throw ArgumentError('不支持的同步实体类型：${entity.runtimeType}'),
    };
