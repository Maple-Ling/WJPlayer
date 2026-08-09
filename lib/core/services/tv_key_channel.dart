// lib/core/services/tv_key_channel.dart
//
// TV 按键通道服务：统一接收 MainActivity.kt 转发的 MENU/专用硬键，
// 再分发到全局按键处理器。
//
// 替代现状：app_router.dart 中 _MainShellState.initState 内联的 MethodChannel handler。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'tv_focus_manager.dart';

/// 按键事件来源
enum KeyEventSource { nativeChannel, flutter }

/// 全局按键处理器签名
/// [isRepeat]：Flutter KeyRepeatEvent（长按自动重复）为 true；原生通道恒为 false。
/// [isUp]：KeyUpEvent（按键松开）为 true；按下/重复为 false。
typedef GlobalKeyHandler = KeyEventResult Function(
    LogicalKeyboardKey key, KeyEventSource source, bool isRepeat, bool isUp);

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
  KeyEventSource source, {
  bool isRepeat = false,
  bool isUp = false,
}) {
  for (final handler in _globalKeyHandlers.reversed.toList(growable: false)) {
    if (handler(key, source, isRepeat, isUp) == KeyEventResult.handled) {
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

    // 没有页面级覆盖时，MENU 在状态栏内外切换：
    // 进入记录来源区域，退出时归还来源焦点（无来源则交还 Flutter 默认焦点树）。
    final manager = TvFocusManager.instance;
    if (manager.activeArea?.config.id == 'main_tabs') {
      manager.exitArea('main_tabs');
    } else {
      manager.enterArea('main_tabs');
    }
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