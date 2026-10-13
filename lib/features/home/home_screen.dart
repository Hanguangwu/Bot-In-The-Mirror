import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../di.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_repository.dart';
import '../chat/chat_screen.dart';

/// 主页面：仓库流驱动的会话列表。
class HomeScreen extends StatefulWidget {
  /// 创建主页面。
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<Color> _avatarColors = <Color>[
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.red,
    Colors.teal,
  ];

  final ConversationRepository _repository = getIt<ConversationRepository>();
  late final Stream<List<Conversation>> _conversationsStream =
      _repository.watchConversations();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue.shade50,
      appBar: AppBar(
        backgroundColor: Colors.blue.shade100,
        title: const Text(
          'Chat with Alice',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: StreamBuilder<List<Conversation>>(
        stream: _conversationsStream,
        builder: (context, snapshot) {
          final conversations = snapshot.data ?? const <Conversation>[];
          if (conversations.isEmpty) {
            return const Center(
              child: Text(
                '还没有会话，点右下角按钮创建',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }
          return ListView.builder(
            itemCount: conversations.length,
            itemBuilder: (context, index) =>
                _buildChatItem(conversations[index]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green,
        onPressed: _showAddBotDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 构建会话列表项。
  Widget _buildChatItem(Conversation conversation) {
    final lastMessageAt = conversation.lastMessageAt;
    return ListTile(
      onTap: () => _openConversation(conversation),
      leading: CircleAvatar(
        backgroundColor: _avatarColor(conversation.id),
        child: Text(
          conversation.title.isEmpty ? 'AI' : conversation.title.substring(0, 1),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(
        conversation.title,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        conversation.lastMessagePreview ?? '开始新的对话',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: lastMessageAt == null
          ? null
          : Text(
              DateFormat('HH:mm').format(lastMessageAt),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
    );
  }

  /// 打开会话。
  void _openConversation(Conversation conversation) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ChatScreen(conversation: conversation),
      ),
    );
  }

  /// 根据会话 ID 稳定地派生头像颜色。
  Color _avatarColor(String id) =>
      _avatarColors[id.hashCode.abs() % _avatarColors.length];

  /// 显示「添加助手」对话框，确认后创建会话并进入。
  Future<void> _showAddBotDialog() async {
    final nameController = TextEditingController();
    final String title =
        await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('添加新助手'),
            content: TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '助手名称',
                hintText: '例如：写作助手',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) =>
                  Navigator.pop(context, value.trim()),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, nameController.text.trim()),
                child: const Text('添加'),
              ),
            ],
          ),
        ) ??
        '';
    nameController.dispose();

    if (title.isEmpty || !mounted) {
      return;
    }
    final conversation = await _repository.createConversation(title: title);
    if (!mounted) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ChatScreen(conversation: conversation),
      ),
    );
  }
}
