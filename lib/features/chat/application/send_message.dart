import '../../../core/ids/ids.dart';
import '../../../domain/ai/ai_client.dart';
import '../../../domain/entities/conversation.dart';
import '../../../domain/repositories/conversation_repository.dart';
import '../../../domain/repositories/settings_store.dart';

/// 发送消息用例：组装历史 → 落库用户消息 → 调用 AI → 落库助手回复。
///
/// 任一步失败都会向上抛 `AppException`；用户消息已保存，不重复插入。
class SendMessage {
  /// 注入仓储、AI 客户端与设置存储。
  SendMessage({
    required ConversationRepository repository,
    required AIClient aiClient,
    required SettingsStore settingsStore,
  })  : _repository = repository,
        _aiClient = aiClient,
        _settingsStore = settingsStore;

  final ConversationRepository _repository;
  final AIClient _aiClient;
  final SettingsStore _settingsStore;

  /// 发送 [text] 到 [conversationId] 对应的会话。
  Future<void> call({required String conversationId, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final history = await _repository.getMessages(conversationId);
    final requestMessages = <AIChatMessage>[
      for (final message in history)
        AIChatMessage(
          role: _toChatRole(message.role),
          content: message.content,
        ),
      AIChatMessage(role: AIChatRole.user, content: trimmed),
    ];

    await _repository.addMessage(
      _buildMessage(
        conversationId: conversationId,
        role: MessageRole.user,
        content: trimmed,
      ),
    );

    final result = await _aiClient.complete(
      AIRequest(
        messages: requestMessages,
        profile: _settingsStore.currentProfile,
      ),
    );

    await _repository.addMessage(
      _buildMessage(
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: result.content,
        aiModel: result.model,
      ),
    );
  }

  /// 构造待落库消息；`id`/`userId`/`deviceId`/时间由仓储写入时统一维护。
  Message _buildMessage({
    required String conversationId,
    required MessageRole role,
    required String content,
    String? aiModel,
  }) {
    final now = DateTime.now();
    return Message(
      id: generateId(),
      userId: '',
      createdAt: now,
      updatedAt: now,
      version: 1,
      deviceId: '',
      conversationId: conversationId,
      role: role,
      type: MessageType.text,
      content: content,
      status: MessageStatus.sent,
      aiModel: aiModel,
    );
  }

  AIChatRole _toChatRole(MessageRole role) {
    switch (role) {
      case MessageRole.user:
        return AIChatRole.user;
      case MessageRole.assistant:
        return AIChatRole.assistant;
      case MessageRole.system:
        return AIChatRole.system;
    }
  }
}
