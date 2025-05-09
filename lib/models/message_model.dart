/// 消息模型类，用于存储聊天消息数据
class MessageModel {
  /// 是否为用户消息
  final bool isUser;
  
  /// 消息内容
  final String message;
  
  /// 消息时间
  final DateTime time;

  /// 构造函数
  MessageModel({
    required this.isUser,
    required this.message,
    required this.time,
  });
}