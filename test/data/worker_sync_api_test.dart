import 'dart:convert';

import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/data/remote/worker_sync_api.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/sync/sync_change.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 固定时间（UTC）。
final DateTime _t = DateTime.utc(2026, 5, 1, 9, 0);

/// 构造一条推送用同步操作。
SyncOperation _op({
  String id = 'op-1',
  String entityId = 'e-1',
  int version = 1,
}) =>
    SyncOperation(
      id: id,
      userId: 'user-1',
      createdAt: _t,
      updatedAt: _t,
      version: 1,
      deviceId: 'device-1',
      entityType: 'task',
      entityId: entityId,
      kind: SyncOperationKind.create,
      payload: <String, Object?>{
        'id': entityId,
        'userId': 'user-1',
        'version': version,
        'updatedAt': _t.toIso8601String(),
        'deviceId': 'device-1',
        'title': '写周报',
      },
    );

/// 便捷构造：基址带尾斜杠（顺带校验归一化）。
WorkerSyncApi _api(http.Client client) => WorkerSyncApi(
      client: client,
      baseUrlProvider: () => 'https://sync.example.com/',
    );

void main() {
  group('WorkerSyncApi', () {
    test('register：URL/方法/请求体正确，解析会话（无需鉴权头）', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://sync.example.com/v1/auth/anonymous');
        expect(request.method, 'POST');
        expect(request.headers['content-type'], 'application/json; charset=utf-8');
        expect(request.headers['authorization'], isNull);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, <String, dynamic>{'userId': 'user-1', 'deviceId': 'device-1'});
        return http.Response(
          jsonEncode(<String, Object?>{
            'token': 'abc123',
            'userId': 'user-1',
            'workspaceId': 'ws-9',
            'deviceId': 'device-1',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final session = await _api(client)
          .register(userId: 'user-1', deviceId: 'device-1');

      expect(session.token, 'abc123');
      expect(session.userId, 'user-1');
      expect(session.workspaceId, 'ws-9');
      expect(session.deviceId, 'device-1');
    });

    test('push：Bearer 头与信封体（信封不含 version/updatedAt/deviceId）', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://sync.example.com/v1/sync/push');
        expect(request.method, 'POST');
        expect(request.headers['content-type'], 'application/json; charset=utf-8');
        expect(request.headers['authorization'], 'Bearer tok-1');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        // 顶层只有 operations（B1：身份/版本均不取信封）。
        expect(body.keys.toList(), <String>['operations']);
        expect(body.containsKey('deviceId'), isFalse);

        final ops = (body['operations'] as List).cast<Map<String, dynamic>>();
        expect(ops, hasLength(1));
        final envelope = ops.single;
        // 信封五字段白名单：不含 version/updatedAt/deviceId（B1）。
        expect(
          envelope.keys.toSet(),
          <String>{'opId', 'entityType', 'entityId', 'kind', 'payload'},
        );
        expect(envelope.containsKey('version'), isFalse);
        expect(envelope.containsKey('updatedAt'), isFalse);
        expect(envelope.containsKey('deviceId'), isFalse);
        expect(envelope['opId'], 'op-1');
        expect(envelope['entityType'], 'task');
        expect(envelope['entityId'], 'e-1');
        expect(envelope['kind'], 'create');
        // payload（实体快照）照常携带 version 等字段。
        final payload = envelope['payload'] as Map<String, dynamic>;
        expect(payload['version'], 1);

        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{'opId': 'op-1', 'status': 'applied'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final resp = await _api(client)
          .push(token: 'tok-1', operations: <SyncOperation>[_op()]);

      expect(resp.results, hasLength(1));
      expect(resp.results.single.opId, 'op-1');
      expect(resp.results.single.status, PushItemStatus.applied);
      expect(resp.results.single.reason, isNull);
    });

    test('push：解析 conflict/rejected 附加字段', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'opId': 'op-1',
                'status': 'conflict',
                'reason': 'stale_version',
                'serverVersion': 4,
                'serverUpdatedAt': '2026-05-01T09:00:00.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final resp = await _api(client)
          .push(token: 'tok-1', operations: <SyncOperation>[_op()]);

      final item = resp.results.single;
      expect(item.status, PushItemStatus.conflict);
      expect(item.reason, 'stale_version');
      expect(item.serverVersion, 4);
      expect(item.serverUpdatedAt!.toUtc(), _t);
    });

    test('pull：GET + 查询参数 + Bearer 头，解析变更/游标/hasMore', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(),
            'https://sync.example.com/v1/sync/pull?cursor=5&limit=200');
        expect(request.method, 'GET');
        expect(request.url.queryParameters,
            <String, String>{'cursor': '5', 'limit': '200'});
        expect(request.headers['authorization'], 'Bearer tok-1');
        return http.Response(
          jsonEncode(<String, Object?>{
            'changes': <Object?>[
              <String, Object?>{
                'seq': 121,
                'entityType': 'task',
                'entityId': 'e-1',
                'kind': 'update',
                'version': 4,
                'deviceId': 'device-remote',
                'updatedAt': '2026-05-01T09:00:00.000Z',
                'payload': <String, Object?>{
                  'id': 'e-1',
                  'userId': 'user-1',
                  'version': 4,
                  'updatedAt': '2026-05-01T09:00:00.000Z',
                  'deviceId': 'device-remote',
                  'title': '远端任务',
                },
              },
            ],
            'cursor': 140,
            'hasMore': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final resp = await _api(client).pull(token: 'tok-1', cursor: 5);

      expect(resp.cursor, 140);
      expect(resp.hasMore, isFalse);
      expect(resp.changes, hasLength(1));
      final change = resp.changes.single;
      expect(change.seq, 121);
      expect(change.entityType, 'task');
      expect(change.entityId, 'e-1');
      expect(change.kind, SyncOperationKind.update);
      expect(change.version, 4);
      expect(change.deviceId, 'device-remote');
      expect(change.updatedAt.toUtc(), _t);
      expect(change.payload['title'], '远端任务');
      expect(change.payload['version'], 4);
    });

    test('401 → SyncApiException(statusCode=401, 远端 code)', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'unauthorized',
              'message': 'token 已失效',
            },
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _api(client).push(token: 'stale', operations: <SyncOperation>[_op()]),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('400 → SyncApiException 带远端错误码（cause 仅日志用）', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/sync/pull');
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'invalid_cursor',
              'message': 'cursor 非法',
            },
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _api(client).pull(token: 'tok-1', cursor: 0),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.code, 'code', 'invalid_cursor')
              .having((e) => e.cause, 'cause', 'cursor 非法'),
        ),
      );
    });

    test('400（注册）→ SyncApiException(invalid_identity)', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/auth/anonymous');
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'invalid_identity',
              'message': 'identity invalid',
            },
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _api(client).register(userId: 'u', deviceId: 'd'),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.code, 'code', 'invalid_identity'),
        ),
      );
    });

    test('网络异常（客户端异常）→ SyncNetworkException', () async {
      final client = MockClient((request) async {
        throw http.ClientException('connection refused');
      });

      await expectLater(
        _api(client).push(token: 'tok-1', operations: <SyncOperation>[_op()]),
        throwsA(isA<SyncNetworkException>()),
      );
      await expectLater(
        _api(client).register(userId: 'u', deviceId: 'd'),
        throwsA(isA<SyncNetworkException>()),
      );
      await expectLater(
        _api(client).pull(token: 'tok-1', cursor: 0),
        throwsA(isA<SyncNetworkException>()),
      );
    });

    test('200 但响应体非法 → SyncDecodeException', () async {
      final client = MockClient((request) async {
        return http.Response('not-json', 200,
            headers: {'content-type': 'application/json'});
      });

      await expectLater(
        _api(client).pull(token: 'tok-1', cursor: 0),
        throwsA(isA<SyncDecodeException>()),
      );
    });

    test('基址归一化：尾斜杠//与已含 /v1/ 均正确拼接、无重复斜杠', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{'opId': 'op-1', 'status': 'applied'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      // 程序化写入 `//` 结尾：不应出现重复斜杠。
      await WorkerSyncApi(client: client, baseUrlProvider: () => 'https://h//')
          .push(token: 't', operations: <SyncOperation>[_op()]);
      // 已含 `/v1/` 的基址：版本段不得重复。
      await WorkerSyncApi(client: client, baseUrlProvider: () => 'https://h/v1/')
          .push(token: 't', operations: <SyncOperation>[_op()]);

      expect(
        requested,
        <String>['https://h/v1/sync/push', 'https://h/v1/sync/push'],
      );
    });
  });
}
