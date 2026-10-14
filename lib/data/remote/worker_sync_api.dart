import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../domain/entities/sync.dart';
import '../../domain/sync/sync_api.dart';
import '../../domain/sync/sync_change.dart';
import 'sync_json.dart';

/// RemoteSyncApi 的 HTTP 实现（§6.2）。
///
/// 构造注入 `http.Client`（默认 `http.Client()`）与基址 provider
/// `String Function()` 便于测试替换 MockClient 与动态切换基址。
class WorkerSyncApi implements RemoteSyncApi {
  /// 创建 Worker 同步 API。
  WorkerSyncApi({
    http.Client? client,
    String Function()? baseUrlProvider,
  })  : _client = client ?? http.Client(),
        _baseUrlProvider = baseUrlProvider ?? (() => '');

  final http.Client _client;
  final String Function() _baseUrlProvider;

  /// 规范化基址：先去掉尾部所有 `/`，再去掉可能已含的版本段 `/v1`。
  ///
  /// 各端点路径（如 `/v1/sync/push`）已自带版本段，故基址无论写作
  /// `https://h`、`https://h/`、`https://h//`、`https://h/v1` 还是
  /// `https://h/v1/`，都能拼出唯一正确、无重复斜杠的 URL。
  String _effectiveBaseUrl() {
    var base = _baseUrlProvider().trim();
    if (base.isEmpty) {
      return '';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/v1')) {
      base = base.substring(0, base.length - 3);
    }
    return base;
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final base = _effectiveBaseUrl();
    if (base.isEmpty) {
      // 若未配置基址，仍返回 Uri（调用方不应触网）。
      return Uri.parse(path);
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  @override
  Future<AnonymousSession> register({
    required String userId,
    required String deviceId,
  }) async {
    final uri = _buildUri('/v1/auth/anonymous');
    final body = SyncJson.buildRegisterRequest(
      userId: userId,
      deviceId: deviceId,
    );
    try {
      final response = await _client.post(
        uri,
        headers: const {
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _apiException(response, fallback: '注册失败', fallbackCode: 'register_failed');
      }
      final data = _decodeJson(response.body);
      return SyncJson.parseRegisterResponse(data);
    } on SocketException catch (e) {
      throw SyncNetworkException('网络连接失败', cause: e);
    } on http.ClientException catch (e) {
      throw SyncNetworkException('网络请求失败', cause: e);
    } on FormatException catch (e) {
      throw SyncDecodeException('响应解析失败', cause: e);
    }
  }

  @override
  Future<PushResponse> push({
    required String token,
    required List<SyncOperation> operations,
  }) async {
    final uri = _buildUri('/v1/sync/push');
    final body = SyncJson.buildPushRequest(operations: operations);
    try {
      final response = await _client.post(
        uri,
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _apiException(response, fallback: '推送失败', fallbackCode: 'push_failed');
      }
      final data = _decodeJson(response.body);
      return SyncJson.parsePushResponse(data);
    } on SocketException catch (e) {
      throw SyncNetworkException('网络连接失败', cause: e);
    } on http.ClientException catch (e) {
      throw SyncNetworkException('网络请求失败', cause: e);
    } on FormatException catch (e) {
      throw SyncDecodeException('响应解析失败', cause: e);
    }
  }

  @override
  Future<PullResponse> pull({
    required String token,
    required int cursor,
    int limit = AppConfig.syncPullLimit,
  }) async {
    final query = SyncJson.buildPullQuery(cursor: cursor, limit: limit);
    final uri = _buildUri('/v1/sync/pull', query);
    try {
      final response = await _client.get(
        uri,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _apiException(response, fallback: '拉取失败', fallbackCode: 'pull_failed');
      }
      final data = _decodeJson(response.body);
      return SyncJson.parsePullResponse(data);
    } on SocketException catch (e) {
      throw SyncNetworkException('网络连接失败', cause: e);
    } on http.ClientException catch (e) {
      throw SyncNetworkException('网络请求失败', cause: e);
    } on FormatException catch (e) {
      throw SyncDecodeException('响应解析失败', cause: e);
    }
  }

  Map<String, Object?> _decodeJson(String body) {
    final data = jsonDecode(body);
    if (data is! Map<String, Object?>) {
      // 尝试规范化
      if (data is Map) {
        return data.map<String, Object?>(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
      throw FormatException('非 JSON 对象响应');
    }
    return data;
  }

  /// 把非 2xx 响应包装为 [SyncApiException]：中文文案 + 远端错误码 + 状态码；
  /// 远端 `error.message` 仅进 `cause`（日志排查用，不直接展示）。
  SyncApiException _apiException(
    http.Response response, {
    required String fallback,
    required String fallbackCode,
  }) {
    String? code;
    String? remoteMessage;
    try {
      final data = _decodeJson(response.body);
      code = SyncJson.tryParseErrorCode(data);
      remoteMessage = SyncJson.tryParseErrorMessage(data);
    } catch (_) {
      // 错误体不是 JSON：忽略解析失败，沿用兜底码。
    }
    return SyncApiException(
      fallback,
      code: code ?? fallbackCode,
      statusCode: response.statusCode,
      cause: remoteMessage,
    );
  }
}
