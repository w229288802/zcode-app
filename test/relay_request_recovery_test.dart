import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/relay_client.dart';
import 'package:zcode_app/core/relay/rpc_codec.dart';

/// 仅在本机回环地址模拟桥接及 RPC 响应，不连接真实账号或 Host。
class _Host {
  late HttpServer server;
  late WebSocket socket;
  void Function(RpcFrame)? onRequest;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] == 'auth_init') {
          socket.add(jsonEncode({'type': 'auth_ack', 'pair_status': 'matched'}));
          return;
        }
        final payload = message['payload'] as Map<String, dynamic>?;
        if (payload == null) return;
        if (payload['zcode_type'] == 'workspace-bridge-open') {
          _data({
            'zcode_type': 'workspace-bridge-ready',
            'requestId': payload['requestId'],
          });
          _frame([RpcCodec.typeInit], {});
        } else if (payload['zcode_type'] == 'rpc-frame') {
          final frame = RpcCodec.decode(base64Decode(payload['dataBase64']));
          if (onRequest != null) {
            onRequest!(frame);
          } else {
            respond(frame, {'status': 'accepted'});
          }
        }
      });
    });
  }

  void _data(Map<String, dynamic> payload) =>
      socket.add(jsonEncode({'type': 'data', 'payload': payload}));

  void _frame(List<dynamic> header, Map<String, dynamic> body) {
    final bytes = <int>[];
    RpcCodec.serialize(bytes, header);
    RpcCodec.serialize(bytes, body);
    _data({'zcode_type': 'rpc-frame', 'dataBase64': base64Encode(bytes)});
  }

  void respond(RpcFrame request, Map<String, dynamic> body) =>
      _frame([RpcCodec.typeOk, request.id], body);

  Future<void> close() async {
    await socket.close();
    await server.close(force: true);
  }
}

void main() {
  late _Host host;
  late RelayClient relay;

  setUp(() async {
    host = _Host();
    await host.start();
    relay = RelayClient(
      config: RelayConfig(
        wsUrl: 'ws://127.0.0.1:${host.server.port}',
        deviceSid: 'test',
        passHash: 'test',
        cookie: '',
      ),
    );
    await relay.connect();
    await relay.openWorkspaceBridge('/test');
  });

  tearDown(() async {
    await relay.disconnect();
    relay.dispose();
    await host.close();
  });

  test('重开桥接后，旧超时回调不会移除编号复用的新请求', () async {
    final timers = <(Timer, void Function())>[];
    try {
      await runZoned(() async {
        final first = relay.rpcCallMap('test', 'first', []);
        final oldTimeout = timers.last;
        await first;

        await relay.openWorkspaceBridge('/test');
        final received = Completer<RpcFrame>();
        host.onRequest = received.complete;
        final second = relay.rpcCallMap('test', 'second', []);
        final request = await received.future;
        expect(request.id, 1); // 桥接重建后编号从 1 开始。

        // 精确触发旧请求的超时，无需等待真实的 30 秒。
        oldTimeout.$1.cancel();
        oldTimeout.$2();
        host.respond(request, {'value': 'second reply'});
        expect(
          await second.timeout(const Duration(seconds: 2)),
          {'value': 'second reply'},
        );
      }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 30)) {
            timers.add((timer, callback));
          }
          return timer;
        },
      ));
    } finally {
      for (final timer in timers) {
        timer.$1.cancel();
      }
    }
  });

  for (final status in ['rejected', 'stale', 'failed']) {
    test('服务端返回 $status 时向发送方报告失败', () async {
      host.onRequest = (request) => host.respond(request, {
        'status': status,
        'reasonCode': 'test.reason',
        'message': 'not sent',
      });
      await expectLater(
        relay.sendConversationCommandV4(
          workspacePath: '/test',
          commandType: 'sendText',
          sessionId: 'session',
          payload: {'text': 'hello'},
        ),
        throwsA(isA<StateError>()),
      );
    });
  }

  test('已接受的发送正常返回', () async {
    final response = await relay.sendConversationCommandV4(
      workspacePath: '/test',
      commandType: 'sendText',
      sessionId: 'session',
      payload: {'text': 'hello'},
    );
    expect(response['status'], 'accepted');
  });
}
