// lib/core/services/tv_key_channel.dart
//
// TV 按键通道服务：统一接收 MainActivity.kt 转发的 MENU/专用硬键，
// 再分发到全局按键处理器或 TvFocusManager。
//
// 替代现状：app_router.dart 中 _MainShellState.initState 内联的 MethodChannel handler。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'tv_focus_manager.dart';

/// 按键事件来源
enum KeyEventSource { nativeChannel, flutter }

/// 全局按键处理器签名
typedef GlobalKeyHandler = KeyEventResult Function(
    LogicalKeyboardKey key, KeyEventSource source);

/// 全局按键处理器注册表。后注册者优先，可让顶层路由覆盖默认行为。
final List<GlobalKeyHandler> _globalKeyHandlers = <GlobalKeyHandler>[];

void registerGlobalKeyHandler(GlobalKeyHandler handler) {
  if (!_globalKeyHandlers.contains(handler)) {
    _globalKeyHandlers.add(handler);
  }
}

void unregisterGlobalKeyHandler(GlobalKeyHandler handler) {
  _globalKeyHandlers.remove(handler);
}

KeyEventResult dispatchGlobalTvKey(
  LogicalKeyboardKey key,
  KeyEventSource source,
) {
  for (final handler in _globalKeyHandlers.reversed.toList(growable: false)) {
    if (handler(key, source) == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
  }
  return KeyEventResult.ignored;
}

/// 在 main.dart 中调用一次，注册原生层 MethodChannel 桥接。
/// 对应 MainActivity.kt 的 tvKeyChannel.invokeMethod() 调用。
void installNativeKeyBridge() {
  const channel = MethodChannel('com.mapleling.wjplayer/tv_key');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'menu') return;

    if (dispatchGlobalTvKey(
          LogicalKeyboardKey.contextMenu,
          KeyEventSource.nativeChannel,
        ) ==
        KeyEventResult.handled) {
      return;
    }

    // 没有页面级覆盖时，MENU 恢复到底部栏上次焦点。
    TvFocusManager.instance.switchArea('main_tabs');
  });
}

/// 将 action 字符串转为 DPad 枚举
DPad? _dpadFromAction(String? action) {
  switch (action) {
    case 'up':    return DPad.up;
    case 'down':  return DPad.down;
    case 'left':  return DPad.left;
    case 'right': return DPad.right;
    default:      return null;
  }
}