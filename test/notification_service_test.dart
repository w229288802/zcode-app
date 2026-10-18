import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/notifications/notification_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  late MethodCall initialization;
  var failClear = false;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return true;
      if (call.method == 'cancelAll' && failClear) {
        throw PlatformException(code: 'test', message: 'clear failed');
      }
      return null;
    });
    await NotificationService.init();
    initialization = calls.firstWhere((call) => call.method == 'initialize');
  });

  setUp(() {
    calls.clear();
    failClear = false;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  });

  tearDownAll(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS 初始化请求提醒、声音和角标权限', () {
    final args = initialization.arguments as Map;
    expect(args['requestAlertPermission'], isTrue);
    expect(args['requestSoundPermission'], isTrue);
    expect(args['requestBadgePermission'], isTrue);
  });

  test('后台完成事件通过 iOS 通知通道显示并保留会话信息', () async {
    NotificationService.notifyTurnComplete(
      taskId: 'task',
      workspaceKey: '/workspace',
      sessionTitle: '测试对话',
    );
    await Future<void>.delayed(Duration.zero);
    final show = calls.singleWhere((call) => call.method == 'show');
    final args = show.arguments as Map;
    expect(args['title'], '任务完成');
    expect(args['body'], contains('测试对话'));
    expect(args['platformSpecifics'], isNotNull);
    expect(jsonDecode(args['payload'] as String), {
      'taskId': 'task',
      'workspaceKey': '/workspace',
    });
  });

  test('前台完成不再弹系统通知', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    NotificationService.notifyTurnComplete(
      taskId: 'task',
      workspaceKey: '/workspace',
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), isEmpty);
  });

  test('统一清除完成、权限和提问通知，下一轮仍能正常通知', () async {
    NotificationService.notifyTurnComplete(
      taskId: 'task',
      workspaceKey: '/workspace',
    );
    NotificationService.notifyPermission(
      taskId: 'task',
      workspaceKey: '/workspace',
      permissionId: 'clear-test',
      toolName: 'Bash',
    );
    NotificationService.notifyQuestion(
      taskId: 'task',
      workspaceKey: '/workspace',
      question: '是否继续？',
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), hasLength(3));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await NotificationService.clearAll();
    expect(calls.where((call) => call.method == 'cancelAll'), hasLength(1));
    expect(calls.where((call) => call.method == 'initialize'), isEmpty);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    NotificationService.notifyTurnComplete(
      taskId: 'next-task',
      workspaceKey: '/workspace',
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), hasLength(4));
  });

  test('重复权限事件只提醒一次', () async {
    for (var i = 0; i < 2; i++) {
      NotificationService.notifyPermission(
        taskId: 'task',
        workspaceKey: '/workspace',
        permissionId: 'dedupe-test',
        toolName: 'Bash',
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), hasLength(1));
  });

  test('从后台回到前台途中处理的积压事件不弹通知', () async {
    // 离开: resumed → inactive → hidden → paused
    for (final s in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      NotificationService.onLifecycleChanged(s);
    }
    NotificationService.notifyTurnComplete(taskId: 'bg', workspaceKey: '/w');
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), hasLength(1));

    // 回来: paused → hidden → inactive, 期间到达的事件属于打开 App 时的补发
    NotificationService.onLifecycleChanged(AppLifecycleState.hidden);
    NotificationService.notifyTurnComplete(taskId: 'late', workspaceKey: '/w');
    NotificationService.onLifecycleChanged(AppLifecycleState.inactive);
    NotificationService.notifyTurnComplete(taskId: 'late', workspaceKey: '/w');
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'show'), hasLength(1));
    NotificationService.debugResetLifecycle();
  });

  test('清除通知失败不影响打开应用', () async {
    failClear = true;
    await expectLater(NotificationService.clearAll(), completes);
  });
}
