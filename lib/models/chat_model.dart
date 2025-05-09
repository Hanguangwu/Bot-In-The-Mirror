/// 聊天模型类，用于存储聊天列表数据
class ChatModel {
  /// 聊天ID，用于唯一标识聊天会话
  final String id;
  
  /// 聊天名称
  final String name;
  
  /// 最后一条消息
  final String lastMessage;
  
  /// 消息时间
  final DateTime time;
  
  /// 是否为机器人
  final bool isBot;
  
  /// 未读消息数量
  final int unreadCount;
  
  /// 头像颜色
  final dynamic avatarColor;
  
  /// AI模型类型
  final String modelType;

  /// 构造函数
  ChatModel({
    required this.id,
    required this.name,
    required this.lastMessage,
    required this.time,
    required this.isBot,
    required this.unreadCount,
    required this.avatarColor,
    this.modelType = 'gpt-3.5-turbo',
  });
}