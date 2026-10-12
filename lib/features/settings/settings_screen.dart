import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../di.dart';
import '../../domain/ai/ai_client.dart';
import '../../domain/entities/ai_provider.dart';
import '../../domain/repositories/settings_store.dart';

/// 设置页：配置 AI 模型参数，支持测试连接与保存。
class SettingsScreen extends StatefulWidget {
  /// 创建设置页。
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsStore _settingsStore = getIt<SettingsStore>();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _temperatureController = TextEditingController();
  final TextEditingController _maxTokensController = TextEditingController();
  late String _selectedModel;
  late List<String> _models;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    final profile = _settingsStore.currentProfile;
    _apiKeyController.text = profile.apiKeyRef ?? '';
    _baseUrlController.text = profile.baseUrl;
    _temperatureController.text = profile.temperature.toString();
    _maxTokensController.text = profile.maxTokens.toString();
    _selectedModel = profile.model;
    _models = <String>[
      if (!AppConfig.commonModels.contains(profile.model)) profile.model,
      ...AppConfig.commonModels,
    ];
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _temperatureController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  /// 由当前输入构造配置（明文 key 存于内存 apiKeyRef）。
  AIProviderProfile _buildProfile() {
    final temperature =
        double.tryParse(_temperatureController.text) ?? AppConfig.defaultTemperature;
    final maxTokens =
        int.tryParse(_maxTokensController.text) ?? AppConfig.defaultMaxTokens;
    return AIProviderProfile(
      name: '默认',
      baseUrl: _baseUrlController.text.trim(),
      model: _selectedModel,
      temperature: temperature,
      maxTokens: maxTokens,
      apiKeyRef: _apiKeyController.text,
    );
  }

  /// 保存设置到内存存储。
  Future<void> _saveSettings() async {
    await _settingsStore.saveProfile(_buildProfile());
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  /// 测试连接：成功/失败均以 SnackBar 反馈，失败只显示异常文案。
  Future<void> _testConnection() async {
    setState(() => _isTesting = true);
    try {
      await getIt<AIClient>().testConnection(_buildProfile());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接成功，模型可正常响应')),
        );
      }
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接失败，请检查配置')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
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
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isTesting ? null : _testConnection,
                icon: _isTesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(_isTesting ? '测试中...' : '测试连接'),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const <Widget>[
                    Text(
                      '关于',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 15),
                    Text(
                      'Chat with Alice 是一个基于OpenAI API的聊天应用，支持多种AI模型。',
                      style: TextStyle(fontSize: 14),
                    ),
                    SizedBox(height: 10),
                    Text(
                      '版本: ${AppConfig.appVersion}',
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

  /// 构建模型选择器。
  Widget _buildModelSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '选择默认模型：',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
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
              if (value != null) {
                setState(() => _selectedModel = value);
              }
            },
            items: _models
                .map(
                  (model) => DropdownMenuItem<String>(
                    value: model,
                    child: Text(model),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  /// 构建文本输入框。
  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool isPassword = false,
    TextInputType keyboardType = TextInputType.text,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
