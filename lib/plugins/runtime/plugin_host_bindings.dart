import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 插件宿主与运行中应用之间的绑定（全局单例）。
///
/// 由 App 在启动时填充：
///  - [container]：用于读取 Emby 客户端、当前用户/服务器、当前播放项等 Provider；
///  - [navigatorKey]：用于插件 UI（Toast/Dialog/打开页面）获取 BuildContext。
///
/// 桌面/TV 端各自有独立导航器，可在各自入口设置对应的 navigatorKey；
/// 未设置时，UI 类调用会安全降级（记录日志并返回 null）。
class PluginHostBindings {
  PluginHostBindings._();
  static final PluginHostBindings instance = PluginHostBindings._();

  ProviderContainer? container;
  GlobalKey<NavigatorState>? navigatorKey;

  BuildContext? get context => navigatorKey?.currentContext;

  bool get isReady => container != null;
}
