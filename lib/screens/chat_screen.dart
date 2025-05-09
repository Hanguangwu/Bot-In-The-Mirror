import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/message_model.dart';
import '../services/ai_service.dart';

/// 聊天界面
class ChatScreen extends StatefulWidget {
  final String chatName;
  final String chatId;
  final String modelType;

  const ChatScreen({
    super.key, 
    required this.chatName, 
    required this.chatId,
    required this.modelType,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final AIService _aiService = AIService();
  final List<MessageModel> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // 添加欢迎消息
    _messages.add(
      MessageModel(
        isUser: false,
        message: '你好，我是${widget.chatName}，有什么可以帮你的？',
        time: DateTime.now(),
      ),
    );
  }

  /// 发送消息
  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final userMessage = _messageController.text;
    _messageController.clear();

    // 添加用户消息
    setState(() {
      _messages.add(
        MessageModel(
          isUser: true,
          message: userMessage,
          time: DateTime.now(),
        ),
      );
      _isLoading = true;
    });

    try {
      // 获取AI回复
      final response = await _aiService.sendMessage(userMessage);
      
      setState(() {
        _messages.add(
          MessageModel(
            isUser: false,
            message: response,
            time: DateTime.now(),
          ),
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(
          MessageModel(
            isUser: false,
            message: '抱歉，发生了错误：$e',
            time: DateTime.now(),
          ),
        );
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.blue,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chatName, 
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)
            ),
            Text(
              '模型: ${widget.modelType}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'clear') {
                setState(() {
                  _messages.clear();
                  _aiService.clearChatSession(widget.chatId);
                  _messages.add(
                    MessageModel(
                      isUser: false,
                      message: '聊天记录已清空，有什么可以帮你的？',
                      time: DateTime.now(),
                    ),
                  );
                });
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: Colors.red),
                    SizedBox(width: 8),
                    Text('清空聊天记录'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length,
              reverse: false,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message);
              },
            ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text('${widget.modelType} 正在思考...', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: '输入消息...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    maxLines: null,
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  backgroundColor: Colors.blue,
                  onPressed: _isLoading ? null : _sendMessage,
                  child: const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建消息气泡 - Telegram风格
  Widget _buildMessageBubble(MessageModel message) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser)
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.blue,
              child: Text(
                widget.chatName.substring(0, 1),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? Colors.blue.shade500 : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.1),
                    spreadRadius: 1,
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isUser)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        widget.chatName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  Text(
                    message.message,
                    style: TextStyle(
                      color: isUser ? Colors.white : Colors.black87,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DateFormat('HH:mm').format(message.time),
                          style: TextStyle(
                            fontSize: 11,
                            color: isUser ? Colors.white70 : Colors.grey.shade500,
                          ),
                        ),
                        if (isUser)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.done_all,
                              size: 14,
                              color: Colors.white70,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (isUser)
            const CircleAvatar(
              radius: 16,
              backgroundColor: Colors.green,
              child: Text(
                '我',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  /// 构建消息输入框
  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(15),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey.shade200,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.send,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示模型信息对话框
  void _showModelInfoDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('当前AI模型信息'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('模型: ${_aiService.currentModel}'),
              const SizedBox(height: 10),
              Text('Temperature: ${_aiService.temperature}'),
              const SizedBox(height: 10),
              Text('Max Tokens: ${_aiService.maxTokens}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}