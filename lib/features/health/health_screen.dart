import 'package:flutter/material.dart';

/// 健康页：M2a 仅占位，具体功能在 M3 实现。
class HealthScreen extends StatelessWidget {
  /// 创建健康占位页。
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('健康'),
      ),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.favorite_border, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              '健康功能将在后续版本提供',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
