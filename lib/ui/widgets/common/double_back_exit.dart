import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import 'app_toast.dart';

/// 首页返回拦截：两秒内连按两次返回键才退出应用，
/// 避免在首页误触一次系统返回就直接退到桌面。
///
/// 非首页的根级 Tab（设置 / 服务器列表）用 [PopToHome] 先回首页；
/// push 入栈的页面无需包裹——系统返回天然逐级 pop 回首页。
class DoubleBackToExit extends StatefulWidget {
  final Widget child;
  const DoubleBackToExit({super.key, required this.child});

  @override
  State<DoubleBackToExit> createState() => _DoubleBackToExitState();
}

class _DoubleBackToExitState extends State<DoubleBackToExit> {
  DateTime? _lastPress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop:false → 拦截 go_router 的“弹到父路由/退出”，改由下方计时逻辑决定。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastPress == null ||
            now.difference(_lastPress!) > const Duration(seconds: 2)) {
          _lastPress = now;
          AppToast.show(context, '再按一次返回键退出');
          return;
        }
        SystemNavigator.pop();
      },
      child: widget.child,
    );
  }
}

/// 非首页的根级 Tab（设置 / 服务器列表）返回拦截：系统返回/手势返回时**先回首页**，
/// 而不是直接退出应用。到了首页再由 [DoubleBackToExit] 决定是否退出。
///
/// [guardServer] 为 true（服务器列表页）时，无服务器无法回首页（会被路由 redirect
/// 挡回），故退回「再按一次退出」逻辑；设置页恒为 false（无服务器时回首页会落到列表页）。
class PopToHome extends ConsumerStatefulWidget {
  final Widget child;
  final bool guardServer;
  const PopToHome({super.key, required this.child, this.guardServer = false});

  @override
  ConsumerState<PopToHome> createState() => _PopToHomeState();
}

class _PopToHomeState extends ConsumerState<PopToHome> {
  DateTime? _lastPress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final hasServer = ref.read(serverListProvider).isNotEmpty;
        if (!widget.guardServer || hasServer) {
          context.go('/home');
          return;
        }
        // 服务器列表页且无服务器：回不了首页，走两次退出。
        final now = DateTime.now();
        if (_lastPress == null ||
            now.difference(_lastPress!) > const Duration(seconds: 2)) {
          _lastPress = now;
          AppToast.show(context, '再按一次返回键退出');
          return;
        }
        SystemNavigator.pop();
      },
      child: widget.child,
    );
  }
}
