import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/relay_client.dart';
import 'package:zcode_app/core/relay/relay_events.dart';
import 'package:zcode_app/providers/chat_provider.dart';

class _Relay extends RelayClient {
  _Relay()
    : super(
        config: const RelayConfig(
          wsUrl: 'wss://unit.test/ws',
          deviceSid: 'test',
          passHash: 'test',
          cookie: '',
        ),
      );

  final readyChanges = StreamController<bool>.broadcast();
  final streams = <StreamController<V4Frame>>[];
  bool ready = true;
  bool failSubscription = false;
  Completer<void>? subscriptionGate;
  int subscriptions = 0;
  int sends = 0;

  @override
  Stream<bool> get onRpcReadyChange => readyChanges.stream;

  void setReady(bool value) {
    ready = value;
    readyChanges.add(value);
  }

  @override
  Future<void> waitRpcReady(Duration timeout) async {
    if (!ready) await readyChanges.stream.firstWhere((v) => v).timeout(timeout);
  }

  @override
  Future<void> ensureBridgeOpen(String workspaceKey, {String? taskId}) async {}

  @override
  Future<Map<String, dynamic>> v4Handshake() async {
    if (!ready) throw StateError('Bridge not ready');
    return {};
  }

  @override
  Future<String> createSessionV4({
    required String workspacePath,
    required String mode,
    String? workspaceIdentity,
  }) async => 'session';

  @override
  Future<Stream<V4Frame>> subscribeConversationV4({
    required String workspacePath,
    required String sessionId,
    String? workspaceIdentity,
    Map<String, dynamic>? base,
    String? visibility,
  }) async {
    subscriptions++;
    await subscriptionGate?.future;
    if (failSubscription) throw StateError('Subscription failed');
    final controller = StreamController<V4Frame>();
    streams.add(controller);
    return controller.stream;
  }

  @override
  Future<Map<String, dynamic>> conversationRowsRangeV4({
    required String workspacePath,
    required String sessionId,
    int? beforeRowId,
    int limit = 50,
    String? workspaceIdentity,
  }) async => {'rows': [], 'hasMore': false};

  @override
  Future<Map<String, dynamic>> sendConversationCommandV4({
    required String workspacePath,
    required String commandType,
    Map<String, dynamic> payload = const {},
    String? workspaceIdentity,
    String? sessionId,
    int? baseRevision,
    String? baseLogEpoch,
    Map<String, dynamic>? envelopeExtras,
  }) async {
    expect(ready, isTrue);
    expect(streams.last.hasListener, isTrue);
    sends++;
    return {'status': 'accepted'};
  }

  void reply(String text) {
    streams.last.add(
      V4Frame(
        topic: 'conversation/session',
        subscriptionId: 'sub-$subscriptions',
        fromSeq: 0,
        toSeq: 1,
        sentAt: DateTime.now(),
        payload: V4DeltasPayload([
          V4RowAppended(V4TurnHeaderRow(rowId: 1, turnId: 'turn')),
          V4RowAppended(V4UserInputRow(rowId: 2, turnId: 'turn', text: 'hello')),
          V4RowAppended(V4AssistantTextRow(rowId: 3, turnId: 'turn', text: text)),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(readyChanges.close());
    for (final stream in streams) {
      unawaited(stream.close());
    }
    super.dispose();
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  late _Relay relay;
  late ChatNotifier notifier;

  setUp(() {
    relay = _Relay();
    notifier = ChatNotifier(
      relay,
      const ChatRef(workspacePath: '/test'),
      preferredModelReader: () => null,
      preferredModelSetter: (_) {},
      mergeDiscovered: (_) {},
    );
  });

  tearDown(() {
    notifier.dispose();
    relay.dispose();
  });

  test('新会话在前台桥接重连后继续接收并显示回复', () async {
    await notifier.sendMessage('hello');
    relay.reply('before');
    await _settle();
    expect(notifier.state.messages.last.content, 'before');

    relay.setReady(false);
    await _settle();
    relay.setReady(true);
    await _settle();
    expect(relay.subscriptions, 2);
    relay.reply('after reconnect');
    await _settle();
    expect(notifier.state.messages.last.content, 'after reconnect');
  });

  test('运行中追加消息等待连接和回复订阅恢复，只发送一次', () async {
    await notifier.sendMessage('hello');
    expect(notifier.state.isResponding, isTrue);
    relay.setReady(false);
    await _settle();

    final gate = relay.subscriptionGate = Completer<void>();
    final sending = notifier.sendMessage('follow up');
    await _settle();
    expect(relay.sends, 1);
    relay.setReady(true);
    await _settle();
    expect(relay.subscriptions, 2);
    expect(relay.sends, 1);

    gate.complete();
    await sending;
    expect(relay.sends, 2);
    expect(relay.subscriptions, 2);
  });

  test('订阅失败时不发送，再次发送可恢复订阅', () async {
    await notifier.sendMessage('hello');
    relay.setReady(false);
    await _settle();
    relay.failSubscription = true;
    relay.setReady(true);
    await _settle();
    expect(notifier.state.error, contains('对话同步失败'));

    await notifier.sendMessage('retry');
    expect(relay.sends, 1);
    expect(notifier.state.error, contains('发送失败'));
    relay.failSubscription = false;
    await notifier.sendMessage('retry');
    expect(relay.sends, 2);
    relay.reply('recovered');
    await _settle();
    expect(notifier.state.messages.last.content, 'recovered');
  });
}
