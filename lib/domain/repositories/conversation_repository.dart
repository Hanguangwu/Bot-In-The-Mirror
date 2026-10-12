import '../entities/conversation.dart';

/// 会话与消息仓储接口（本地持久化驱动）。
///
/// 页面通过 `watch*` 流响应式刷新，不直接持有业务状态。
abstract interface class ConversationRepository {
  /// 监听全部会话：按 lastMessageAt 倒序，不含已删除。
  Stream<List<Conversation>> watchConversations();

  /// 一次性获取全部会话（同一排序规则）。
  Future<List<Conversation>> getConversations();

  /// 监听指定会话的消息：按 createdAt 正序。
  Stream<List<Message>> watchMessages(String conversationId);

  /// 一次性获取指定会话的消息。
  Future<List<Message>> getMessages(String conversationId);

  /// 获取单个会话；不存在或已删除时返回 null。
  Future<Conversation?> getConversation(String conversationId);

  /// 创建会话（id/时间/版本由实现维护）。
  Future<Conversation> createConversation({required String title});

  /// 更新会话。
  Future<Conversation> updateConversation(Conversation conversation);

  /// 追加消息，并自动维护 version + updatedAt。
  Future<Message> addMessage(Message message);

  /// 物理删除指定会话的全部消息（M1 起改为墓碑）。
  Future<void> clearMessages(String conversationId);

  /// 软删除会话（写入墓碑）。
  Future<void> deleteConversation(String conversationId);

  /// 表为空时创建默认「AI助手」会话；幂等。
  Future<Conversation> ensureDefaultConversation();
}
