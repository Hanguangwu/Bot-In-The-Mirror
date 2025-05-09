import 'package:flutter/material.dart';
import '../services/ai_service.dart';

/// 设置界面，用于配置AI模型参数
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AIService _aiService = AIService();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _temperatureController = TextEditingController();
  final TextEditingController _maxTokensController = TextEditingController();
  String _selectedModel = 'gpt-3.5-turbo';

  @override
  void initState() {
    super.initState();
    _apiKeyController.text = _aiService.apiKey;
    _baseUrlController.text = _aiService.baseUrl;
    _temperatureController.text = _aiService.temperature.toString();
    _maxTokensController.text = _aiService.maxTokens.toString();
    _selectedModel = _aiService.currentModel;
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _temperatureController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  /// 保存设置
  void _saveSettings() {
    // 验证输入
    final temperature = double.tryParse(_temperatureController.text) ?? 0.7;
    final maxTokens = int.tryParse(_maxTokensController.text) ?? 2000;

    // 更新服务配置
    _aiService.updateSettings(
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
      model: _selectedModel,
      temperature: temperature,
      maxTokens: maxTokens,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue.shade50,
      appBar: AppBar(
        backgroundColor: Colors.blue.shade100,
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI模型设置',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            _buildModelSelector(),
            const SizedBox(height: 20),
            _buildTextField(
              label: 'API密钥',
              controller: _apiKeyController,
              isPassword: true,
            ),
            const SizedBox(height: 15),
            _buildTextField(
              label: 'API基础URL',
              controller: _baseUrlController,
              hint: 'https://api.openai.com/v1',
            ),
            const SizedBox(height: 15),
            _buildTextField(
              label: 'Temperature (0.0-1.0)',
              controller: _temperatureController,
              keyboardType: TextInputType.number,
              hint: '0.7',
            ),
            const SizedBox(height: 15),
            _buildTextField(
              label: 'Max Tokens',
              controller: _maxTokensController,
              keyboardType: TextInputType.number,
              hint: '2000',
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveSettings,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                child: const Text('保存设置'),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '关于',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'Chat with Alice 是一个基于OpenAI API的聊天应用，支持多种AI模型。',
                      style: TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '版本: 1.0.0',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建模型选择器
  Widget _buildModelSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选择默认模型：', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<String>(
            value: _selectedModel,
            isExpanded: true,
            underline: const SizedBox(),
            onChanged: (value) {
              setState(() {
                _selectedModel = value!;
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
      ],
    );
  }

  /// 构建文本输入框
  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool isPassword = false,
    TextInputType keyboardType = TextInputType.text,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: isPassword,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
      ],
    );
  }
}