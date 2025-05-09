import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import '../models/message_model.dart';

/// AI服务类，用于处理与OpenAI API的通信
class AIService extends ChangeNotifier {
  // 单例模式
  static final AIService _instance = AIService._internal();
  factory AIService() => _instance;
  AIService._internal();

  // 默认设置
  String _apiKey = 'sk-xxxxxxxxxxxxxxxxxxxxxxxxx';
  String _baseUrl = 'https://api.chatanywhere.tech/v1';
  String _currentModel = 'gpt-3.5-turbo';
  double _temperature = 0.7;
  int _maxTokens = 2000;
  
  // 支持多个聊天会话
  final Map<String, List<Map<String, String>>> _chatSessions = {};
  String _currentChatId = 'default';
  
  // 可用模型列表
  final List<String> _availableModels = [
    'gpt-3.5-turbo',
    'gpt-4',
    'gpt-4o-mini',
    'gpt-4o',
    'claude-3-opus-20240229',
    'claude-3-sonnet-20240229'
  ];
  
  // 获取当前会话的消息
  List<Map<String, String>> get _messages => 
      _chatSessions[_currentChatId] ?? (_chatSessions[_currentChatId] = []);

  // Getters
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get currentModel => _currentModel;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  List<String> get availableModels => _availableModels;
  
  /// 设置当前聊天会话ID
  void setChatSession(String chatId) {
    _currentChatId = chatId;
    if (!_chatSessions.containsKey(chatId)) {
      _chatSessions[chatId] = [];
    }
    notifyListeners();
  }
  
  /// 获取指定聊天会话的所有消息
  List<MessageModel> getChatMessages(String chatId) {
    final messages = _chatSessions[chatId] ?? [];
    return messages.map((msg) => MessageModel(
      isUser: msg['role'] == 'user',
      message: msg['content'] ?? '',
      time: DateTime.now(),
    )).toList();
  }

  /// 更新设置
  void updateSettings({
    required String apiKey,
    required String baseUrl,
    required String model,
    required double temperature,
    required int maxTokens,
  }) {
    _apiKey = apiKey;
    _baseUrl = baseUrl;
    _currentModel = model;
    _temperature = temperature;
    _maxTokens = maxTokens;
    notifyListeners();
  }

  /// 发送消息到AI服务
  Future<String> sendMessage(String prompt) async {
    _messages.add({
      'role': 'user',
      'content': prompt,
    });

    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _currentModel,
          'messages': _messages,
          'temperature': _temperature,
          'max_tokens': _maxTokens,
        }),
      );

      if (res.statusCode == 200) {
        String content =
            jsonDecode(res.body)['choices'][0]['message']['content'];
        content = content.trim();

        _messages.add({
          'role': 'assistant',
          'content': content,
        });
        return content;
      }
      return '发生错误：${res.statusCode} - ${res.body}';
    } catch (e) {
      return '连接错误：$e';
    }
  }

  /// 清除当前会话的消息历史
  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }
  
  /// 清除指定会话的消息历史
  void clearChatSession(String chatId) {
    if (_chatSessions.containsKey(chatId)) {
      _chatSessions[chatId]?.clear();
      notifyListeners();
    }
  }
  
  /// 删除聊天会话
  void deleteChatSession(String chatId) {
    if (_chatSessions.containsKey(chatId)) {
      _chatSessions.remove(chatId);
      notifyListeners();
    }
  }

  /// 生成图像
  Future<String> generateImage(String prompt) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/images/generations'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'prompt': prompt,
          'n': 1,
          'size': '512x512',
        }),
      );

      if (res.statusCode == 200) {
        return jsonDecode(res.body)['data'][0]['url'];
      }
      return '生成图像失败：${res.statusCode} - ${res.body}';
    } catch (e) {
      return '连接错误：$e';
    }
  }
}