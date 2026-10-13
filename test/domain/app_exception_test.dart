import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('异常层级', () {
    test('所有子类都是 AppException / Exception', () {
      expect(const ValidationException('参数非法'), isA<AppException>());
      expect(const NetworkException('网络不可用'), isA<AppException>());
      expect(const AIProviderException('服务异常'), isA<AppException>());
      expect(const StorageException('写入失败'), isA<AppException>());
      expect(const NotFoundException('资源不存在'), isA<AppException>());
      expect(const UnsupportedException('暂未支持'), isA<AppException>());
      expect(const ValidationException('参数非法'), isA<Exception>());
    });

    test('错误码机器可读且稳定', () {
      expect(const ValidationException('x').code, 'validation');
      expect(const NetworkException('x').code, 'network');
      expect(const AIProviderException('x').code, 'ai_provider');
      expect(const StorageException('x').code, 'storage');
      expect(const NotFoundException('x').code, 'not_found');
      expect(const UnsupportedException('x').code, 'unsupported');
      expect(const PlanValidationException('x').code, 'planInvalid');
      expect(const ConflictException('x').code, 'conflict');
    });

    test('message 为可直接展示的中文文案', () {
      expect(const ValidationException('请输入内容').message, '请输入内容');
    });
  });

  group('toString 安全', () {
    test('包含 code 与 message', () {
      final text = const NetworkException('网络连接失败').toString();
      expect(text, contains('network'));
      expect(text, contains('网络连接失败'));
    });

    test('base 异常可携带 cause', () {
      final text = NetworkException(
        '网络连接失败',
        cause: StateError('timeout'),
      ).toString();
      expect(text, contains('cause'));
    });

    test('新异常 toString 安全（含可选 cause 场景）', () {
      const secret = 'sk-test-secret-key';
      final planText = PlanValidationException(
        'AI 返回的任务计划格式无效',
        cause: StateError('bad json'),
      ).toString();
      expect(planText, contains('planInvalid'));
      expect(planText, contains('AI 返回的任务计划格式无效'));
      expect(planText, contains('cause'));

      final conflictText = ConflictException(
        '状态冲突',
        cause: 'invalidState',
      ).toString();
      expect(conflictText, contains('conflict'));
      expect(conflictText, contains('状态冲突'));
      expect(conflictText, isNot(contains(secret)));
    });

    test('AIProviderException.toString 绝不泄露密钥或完整响应体', () {
      const secret = 'sk-test-secret-key-1234567890';
      const body = '{"error":{"message":"invalid api key $secret"}}';
      final exception = AIProviderException(
        'AI 服务返回错误',
        statusCode: 401,
        body: body,
      );
      final text = exception.toString();

      expect(text, contains('ai_provider'));
      expect(text, contains('401'));
      expect(text, contains('AI 服务返回错误'));
      // 关键安全断言：不包含密钥、不包含完整响应体。
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains('sk-test')));
      expect(text, isNot(contains('invalid api key')));
      expect(text, isNot(contains('{')));
    });

    test('statusCode 可选时仍可安全输出', () {
      final text = const AIProviderException(
        'AI 服务返回错误',
        body: 'sk-leak-should-not-appear',
      ).toString();
      expect(text, isNot(contains('sk-leak')));
      expect(text, contains('AI 服务返回错误'));
    });
  });
}
