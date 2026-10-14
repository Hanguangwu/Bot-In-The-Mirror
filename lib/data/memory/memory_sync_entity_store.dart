import '../../domain/sync/entity_serializer.dart';
import '../../domain/sync/lww.dart';
import '../../domain/sync/sync_change.dart';
import '../../domain/sync/sync_entity_store.dart';
import 'memory_ai_plan_repository.dart';
import 'memory_calendar_entry_repository.dart';
import 'memory_conversation_repository.dart';
import 'memory_project_repository.dart';
import 'memory_task_repository.dart';

/// 内存版远端变更应用实现（§6.3），语义与 Drift 的 `SyncEntityStoreImpl` 等价。
///
/// 聚合六个内存仓储，委托其**数据层内部「原始写入」窄接缝**
/// （`applyRemoteConversation`/`applyRemoteSnapshot` 等，非域接口）——
/// **不入同步队列**，但照常广播变更流供 UI 刷新。以 LWW（[acceptVersion]）决定
/// 是否落地；conversation 接缝保留本地派生列。
///
/// 未知 `entityType` → 返回 false 且不崩。
class MemorySyncEntityStore implements SyncEntityStore {
  /// 创建实现；须注入装配时共享的同一批内存仓储实例。
  MemorySyncEntityStore({
    required MemoryConversationRepository conversations,
    required MemoryTaskRepository tasks,
    required MemoryAIPlanRepository plans,
    required MemoryCalendarEntryRepository calendarEntries,
    required MemoryProjectRepository projects,
  })  : _conversations = conversations,
        _tasks = tasks,
        _plans = plans,
        _calendarEntries = calendarEntries,
        _projects = projects;

  final MemoryConversationRepository _conversations;
  final MemoryTaskRepository _tasks;
  final MemoryAIPlanRepository _plans;
  final MemoryCalendarEntryRepository _calendarEntries;
  final MemoryProjectRepository _projects;

  @override
  Future<bool> applyRemote(SyncChange change) async {
    switch (change.entityType) {
      case 'conversation':
        final entity = ConversationSync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _conversations.localVersionOfConversation(entity.id),
        )) {
          return false;
        }
        _conversations.applyRemoteConversation(entity);
        return true;
      case 'message':
        final entity = MessageSync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _conversations.localVersionOfMessage(entity.id),
        )) {
          return false;
        }
        _conversations.applyRemoteMessage(entity);
        return true;
      case 'task':
        final entity = TaskSync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _tasks.localVersionOf(entity.id),
        )) {
          return false;
        }
        _tasks.applyRemoteSnapshot(entity);
        return true;
      case 'ai_plan':
        final entity = AIPlanSync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _plans.localVersionOf(entity.id),
        )) {
          return false;
        }
        _plans.applyRemoteSnapshot(entity);
        return true;
      case 'calendar_entry':
        final entity = CalendarEntrySync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _calendarEntries.localVersionOf(entity.id),
        )) {
          return false;
        }
        _calendarEntries.applyRemoteSnapshot(entity);
        return true;
      case 'project':
        final entity = ProjectSync.fromSyncJson(change.payload);
        if (!_accept(
          entity.version,
          entity.updatedAt,
          _projects.localVersionOf(entity.id),
        )) {
          return false;
        }
        _projects.applyRemoteSnapshot(entity);
        return true;
      default:
        return false;
    }
  }

  @override
  Future<({int version, DateTime updatedAt})?> localVersion(
    String entityType,
    String entityId,
  ) async {
    switch (entityType) {
      case 'conversation':
        return _conversations.localVersionOfConversation(entityId);
      case 'message':
        return _conversations.localVersionOfMessage(entityId);
      case 'task':
        return _tasks.localVersionOf(entityId);
      case 'ai_plan':
        return _plans.localVersionOf(entityId);
      case 'calendar_entry':
        return _calendarEntries.localVersionOf(entityId);
      case 'project':
        return _projects.localVersionOf(entityId);
      default:
        return null;
    }
  }

  /// LWW 判定（§7.1）；委托 [acceptVersion] 统一语义。
  bool _accept(
    int incomingVersion,
    DateTime incomingUpdatedAt,
    ({int version, DateTime updatedAt})? stored,
  ) {
    return acceptVersion(
      incomingVersion: incomingVersion,
      incomingUpdatedAt: incomingUpdatedAt,
      storedVersion: stored?.version,
      storedUpdatedAt: stored?.updatedAt,
    );
  }
}
