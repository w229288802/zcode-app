import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/entry_workspace.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';
import '../../../providers/app_providers.dart';

/// 启动页 — 黑底 + Z logo,与原生 launch_background.xml 无缝衔接。
/// 检查 session → 连接 relay → 加载工作区 → 进入主页。
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  String _status = '正在连接...';

  /// 连接迟迟不成功时露出"重新输入链接"入口 (旧链接失效/密码已改时,
  /// 否则用户只能对着加载条干等, 进不了登录页换新链接)
  bool _showEscape = false;
  Timer? _escapeTimer;

  /// 已离开启动页 (手动换链接 / 超时跳转), 后台还在跑的连接流程不再导航
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: AppEase.out);
    _controller.forward();
    _escapeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showEscape = true);
    });
    _checkSession();
  }

  void _go(String location) {
    if (!mounted || _left) return;
    _left = true;
    context.go(location);
  }

  /// 放弃当前连接, 回登录页粘贴/扫码新链接
  Future<void> _reenterLink() async {
    if (_left) return;
    final client = ref.read(relayClientProvider);
    _go(AppRoutes.login);
    try {
      await client?.disconnect();
    } catch (_) {}
  }

  /// 认证类失败: 链接已失效 / 密码已修改 / Cookie 过期, 重试无意义, 需换链接
  static bool _isAuthFailure(Object? e) {
    final s = '$e';
    return s.contains('Auth timeout') ||
        s.contains('Pair status') ||
        s.contains('Auth failed') ||
        s.contains('Timeout: bootstrap-request');
  }

  Future<void> _checkSession() async {
    await Future.delayed(const Duration(milliseconds: 600));

    if (!mounted || _left) return;

    final session = ref.read(sessionProvider);
    session.when(
      data: (s) {
        if (s != null && s.isValid) {
          _connectRelay();
        } else {
          _go(AppRoutes.login);
        }
      },
      loading: () {
        Future.delayed(const Duration(milliseconds: 300), _checkSession);
      },
      error: (_, __) {
        _go(AppRoutes.login);
      },
    );
  }

  /// 连接 relay + 开 bridge + 加载数据, 完成后直达聊天页
  Future<void> _connectRelay() async {
    if (!mounted || _left) return;
    setState(() => _status = '正在连接服务器...');

    try {
      // 1) 连接 relay + 加载工作区 (load 内部吞错写入 state, 这里按 state 判定)
      await ref
          .read(workspaceListProvider.notifier)
          .load()
          .timeout(const Duration(seconds: 40));
      final loaded = ref.read(workspaceListProvider);
      if (loaded.hasError) {
        final err = loaded.error;
        if (_isAuthFailure(err)) {
          // 链接失效/密码已改: 主页重试也是同样结果, 直接回登录页换链接
          appLog.w('[Splash] 认证失败, 回登录页重新输入链接: $err');
          await _reenterLink();
          return;
        }
        throw err ?? StateError('bootstrap failed');
      }

      if (!mounted || _left) return;
      setState(() => _status = '正在建立通道...');

      // 2) 选定入口工作区 (上次打开 / 默认) 并开它的 bridge → RPC ready
      //    模型/技能都依赖 _rpcCall, 必须先开 bridge
      final workspaces = ref.read(workspaceListProvider).valueOrNull;
      final repo = ref.read(workspaceRepositoryProvider);
      final entry = await pickEntryWorkspace(workspaces ?? const []);
      if (entry != null && repo != null) {
        // 更新选中工作区 (聊天页标题/identity 用)
        ref.read(selectedWorkspaceProvider.notifier).state = entry;
        try {
          // 远程工作区 bridge-open 必须传 identity (3.7.7 实测), 本地工作区两者相同
          await repo
              .openWorkspace(entry.workspaceIdentity)
              .timeout(const Duration(seconds: 20));
        } catch (e) {
          // bridge 失败不阻塞进入
          appLog.w('[Splash] 入口工作区 bridge 打开失败 (不阻塞): $e');
        }
      }

      if (!mounted || _left) return;
      setState(() => _status = '正在加载数据...');

      // 3) RPC ready 后, 模型/技能会通过 onRpcReadyChange 自动加载
      //    这里等一下让它们有机会完成
      try {
        await ref
            .read(modelListProvider.notifier)
            .refresh()
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        appLog.w('[Splash] 模型列表预加载失败/超时 (不阻塞): $e');
      }

      // 直达聊天页 (对齐网页手机端); 无工作区时回退主页
      if (entry != null) {
        _go(
          '${AppRoutes.chat}?workspace=${Uri.encodeComponent(entry.workspaceKey)}',
        );
      } else {
        _go(AppRoutes.home);
      }
    } catch (e) {
      // 连接失败也进入主页 (主页有重试)
      appLog.w('[Splash] 启动连接失败, 直接进入主页 (主页可重试): $e');
      _go(AppRoutes.home);
    }
  }

  @override
  void dispose() {
    _escapeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Z logo
              Image.asset(
                'assets/images/app_icon.png',
                width: 112,
                height: 112,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 56),
              // 条状加载条 (圆角, 深色背景上克制的白色)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: const SizedBox(
                  width: 128,
                  height: 4,
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: Color.fromRGBO(255, 255, 255, 0.10),
                    valueColor: AlwaysStoppedAnimation(
                      Color.fromRGBO(255, 255, 255, 0.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _status,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: AppTextSizes.bodySm,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              AnimatedOpacity(
                opacity: _showEscape ? 1 : 0,
                duration: AppDur.base,
                curve: AppEase.out,
                child: IgnorePointer(
                  ignoring: !_showEscape,
                  child: TextButton.icon(
                    onPressed: _reenterLink,
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('连接太久? 重新输入链接'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white.withValues(alpha: 0.7),
                      minimumSize: const Size(0, AppTouch.min),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
