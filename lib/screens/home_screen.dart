import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/chat_model.dart';
import '../services/ai_service.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// 主页面，显示聊天列表
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // AI服务实例
  final AIService _aiService = AIService();
  
  // 聊天列表数据
  final List<ChatModel> _chats = [
    ChatModel(
      id: 'chat_ai_assistant',
      name: 'AI助手',
      lastMessage: '你好，我是AI助手，有什么可以帮你的？',
      time: DateTime.now().subtract(const Duration(minutes: 5)),
      isBot: true,
      unreadCount: 1,
      avatarColor: Colors.purple,
    ),
    ChatModel(
      id: 'chat_creative_assistant',
      name: '创意助手',
      lastMessage: '我可以帮你生成创意内容和图片',
      time: DateTime.now().subtract(const Duration(hours: 2)),
      isBot: true,
      unreadCount: 0,
      avatarColor: Colors.orange,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue.shade50,
      appBar: AppBar(
        backgroundColor: Colors.blue.shade100,
        title: const Text('Chat with Alice', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: _chats.length,
        itemBuilder: (context, index) {
          final chat = _chats[index];
          return _buildChatItem(chat);
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green,
        child: const Icon(Icons.add),
        onPressed: () {
          _showAddBotDialog();
        },
      ),
    );
  }

  /// 构建聊天项目
  Widget _buildChatItem(ChatModel chat) {
    return ListTile(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              chatName: chat.name,
              chatId: chat.id,
              modelType: chat.modelType,
            ),
          ),
        );
      },
      leading: CircleAvatar(
        backgroundColor: chat.avatarColor,
        child: Text(
          chat.name.substring(0, 1),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(
        chat.name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        chat.lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            DateFormat('HH:mm').format(chat.time),
            style: TextStyle(
              color: chat.unreadCount > 0 ? Colors.green : Colors.grey,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          if (chat.unreadCount > 0)
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                chat.unreadCount.toString(),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  /// 显示添加机器人对话框
  void _showAddBotDialog() {
    final TextEditingController nameController = TextEditingController();
    final List<Color> avatarColors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.red,
      Colors.teal,
    ];
    Color selectedColor = avatarColors.first;
    String selectedModel = _aiService.availableModels.first;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('添加新助手'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '助手名称',
                    hintText: '例如：写作助手',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('选择模型：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: DropdownButton<String>(
                    value: selectedModel,
                    isExpanded: true,
                    underline: const SizedBox(),
                    onChanged: (value) {
                      setState(() {
                        selectedModel = value!;
                      });
                    },
                    items: _aiService.availableModels.map((model) {
                      return DropdownMenuItem<String>(
                        value: model,
                        child: Text(model),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('选择头像颜色：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  children: avatarColors.map((color) {
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          selectedColor = color;
                        });
                      },
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: color,
                        child: selectedColor == color
                            ? const Icon(Icons.check, color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (nameController.text.trim().isNotEmpty) {
                  final chatId = 'chat_${DateTime.now().millisecondsSinceEpoch}';
                  setState(() {
                    _chats.add(
                      ChatModel(
                        id: chatId,
                        name: nameController.text.trim(),
                        lastMessage: '你好，我是${nameController.text.trim()}，有什么可以帮你的？',
                        time: DateTime.now(),
                        isBot: true,
                        unreadCount: 0,
                        avatarColor: selectedColor,
                        modelType: selectedModel,
                      ),
                    );
                  });
                  // 创建新的聊天会话
                  _aiService.setChatSession(chatId);
                  Navigator.pop(context);
                }
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );}
}