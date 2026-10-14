/// 应用统一异常层级。
///
/// 所有面向用户的错误都继承 [AppException]。[AppException.message] 为中文、
/// 可直接展示给用户的文案；[AppException.code] 为机器可读错误码，
/// 便于日志与测试断言。
///
/// 安全约定：`toString()` 绝不打印 API Key 或完整响应体。原始响应体只允许
/// 存放在 [AIProviderException.body] 中用于日志摘要，禁止直接展示或打印。
sealed class AppException implements Exception {
  /// 创建异常基类；调用方应使用具体子类。
  const AppException(this.message, {required this.code, this.cause});

  /// 中文用户可读文案，可直接展示。
  final String message;

  /// 机器可读错误码：
  /// validation / network / ai_provider / storage / not_found / unsupported /
  /// planInvalid / conflict / sync_network / sync_decode；`SyncApiException.code`
  /// 为远端错误码。
  final String code;

  /// 原始错误（异常对象或摘要），仅用于日志排查，不直接展示给用户。
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('$code: $message');
    if (cause != null) {
      buffer.write(' | cause: $cause');
    }
    return buffer.toString();
  }
}

/// 输入校验失败（参数非法、必填缺失等）。
class ValidationException extends AppException {
  /// 创建校验异常。
  const ValidationException(super.message, {super.cause})
      : super(code: 'validation');
}

/// 网络请求失败（超时、连接错误、无网络等）。
class NetworkException extends AppException {
  /// 创建网络异常。
  const NetworkException(super.message, {super.cause}) : super(code: 'network');
}

/// AI 服务返回错误（非 2xx、响应体解析失败等）。
class AIProviderException extends AppException {
  /// 创建 AI 服务异常。
  ///
  /// [body] 仅用于日志摘要，禁止向用户展示或写入 `toString()`。
  const AIProviderException(
    super.message, {
    this.statusCode,
    this.body,
    super.cause,
  }) : super(code: 'ai_provider');

  /// HTTP 状态码；非 HTTP 错误时为 null。
  final int? statusCode;

  /// 原始响应体（可能含敏感信息，仅用于日志摘要，绝不展示/打印）。
  final String? body;

  @override
  String toString() {
    final buffer = StringBuffer('ai_provider');
    if (statusCode != null) {
      buffer.write('[$statusCode]');
    }
    buffer.write(': $message');
    // 刻意不输出 body，避免泄露密钥或完整响应体。
    return buffer.toString();
  }
}

/// 本地存储读写失败。
class StorageException extends AppException {
  /// 创建存储异常。
  const StorageException(super.message, {super.cause}) : super(code: 'storage');
}

/// 目标资源不存在。
class NotFoundException extends AppException {
  /// 创建资源不存在异常。
  const NotFoundException(super.message, {super.cause})
      : super(code: 'not_found');
}

/// 功能尚未支持（例如 M0 阶段的 AI 计划拆解）。
class UnsupportedException extends AppException {
  /// 创建未支持异常。
  const UnsupportedException(super.message, {super.cause})
      : super(code: 'unsupported');
}

/// AI 计划 JSON 解析或校验失败（未知变更类型、格式非法等）。
class PlanValidationException extends AppException {
  /// 创建计划校验异常。
  const PlanValidationException(super.message, {super.cause})
      : super(code: 'planInvalid');
}

/// 状态或数据冲突（目标不存在、状态不匹配等）。
class ConflictException extends AppException {
  /// 创建冲突异常。
  const ConflictException(super.message, {super.cause})
      : super(code: 'conflict');
}

/// 同步 API 返回非 2xx 或错误体（§6.4）。
///
/// [code] 为远端错误码（如 `invalid_identity`/`invalid_cursor`），
/// [statusCode] 为 HTTP 状态码。响应体摘要仅用于日志，禁止展示明文 token。
class SyncApiException extends AppException {
  /// 创建同步 API 异常。
  const SyncApiException(
    super.message, {
    required super.code,
    this.statusCode,
    super.cause,
  });

  /// HTTP 状态码；非 HTTP 错误时为 null。
  final int? statusCode;

  @override
  String toString() {
    final buffer = StringBuffer(code);
    if (statusCode != null) {
      buffer.write('[$statusCode]');
    }
    buffer.write(': $message');
    return buffer.toString();
  }
}

/// 同步网络异常（超时、连接失败、无网络等，§6.4/§7.4）。
class SyncNetworkException extends AppException {
  /// 创建同步网络异常。
  const SyncNetworkException(super.message, {super.cause})
      : super(code: 'sync_network');
}

/// 同步数据解析失败（快照结构/类型/枚举非法，§6.4）。
class SyncDecodeException extends AppException {
  /// 创建同步解码异常。
  const SyncDecodeException(super.message, {super.cause})
      : super(code: 'sync_decode');
}
