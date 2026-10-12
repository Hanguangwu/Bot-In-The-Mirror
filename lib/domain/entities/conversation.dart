import 'dart:convert';

import 'syncable_entity.dart';

/// 消息角色。
enum MessageRole {
  /// 用户发送。
  user,

  /// AI 助手回复。
  assistant,

  /// 系统提示或系统事件。
  system,
}

/// 消息类型。
enum MessageType {
  /// 纯文本。
  text,

  /// 语音转写文本。
  voiceTranscription,

  /// 图片引用（本地路径或安全引用，不存原图）。
  imageReference,

  /// 系统事件（如「已清空聊天记录」）。
  systemEvent,
}

/// 消息发送状态。
enum MessageStatus {
  /// 发送中。
  sending,

  /// 已发送/落库完成。
  sent,

  /// 发送失败。
  failed,
}

/// 会话。
class Conversation extends SyncableEntity {
  /// 创建会话实体。
  const Conversation({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.title,
    this.isArchived = false,
    this.lastMessagePreview,
    this.lastMessageAt,
  });

  /// 会话标题。
  final String title;

  /// 是否归档。
  final bool isArchived;

  /// 最近一条消息的预览文本。
  final String? lastMessagePreview;

  /// 最近一条消息的时间。
  final DateTime? lastMessageAt;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Conversation copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? title,
    bool? isArchived,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      title: title ?? this.title,
      isArchived: isArchived ?? this.isArchived,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    );
  }
}

/// 消息。
///
/// `metadata` 约定为可 `jsonEncode` 的键值对（仅原始类型、List、Map），
/// M0 阶段恒为空。
class Message extends SyncableEntity {
  /// 创建消息实体。
  const Message({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.conversationId,
    required this.role,
    required this.type,
    required this.content,
    required this.status,
    this.aiModel,
    this.metadata = const <String, Object?>{},
  });

  /// 所属会话 ID。
  final String conversationId;

  /// 消息角色。
  final MessageRole role;

  /// 消息类型。
  final MessageType type;

  /// 消息正文。
  final String content;

  /// 发送状态。
  final MessageStatus status;

  /// 生成该消息的模型名（用户消息为空）。
  final String? aiModel;

  /// 附加元数据，必须可 JSON 编码。
  final Map<String, Object?> metadata;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Message copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? conversationId,
    MessageRole? role,
    MessageType? type,
    String? content,
    MessageStatus? status,
    String? aiModel,
    Map<String, Object?>? metadata,
  }) {
    return Message(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      status: status ?? this.status,
      aiModel: aiModel ?? this.aiModel,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// 将 [Message.metadata] 编码为 JSON 字符串，供本地数据库 TEXT 列存储。
String encodeMetadata(Map<String, Object?> metadata) => jsonEncode(metadata);

/// 解析数据库中的 metadata JSON 字符串。
///
/// 输入为空或非法时返回空 Map，保证读取路径健壮。
Map<String, Object?> decodeMetadata(String? source) {
  if (source == null || source.isEmpty) {
    return <String, Object?>{};
  }
  try {
    final Object? decoded = jsonDecode(source);
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value),
      );
    }
  } on FormatException {
    // 非法 JSON 视为空元数据，避免读取路径崩溃。
  }
  return <String, Object?>{};
}
