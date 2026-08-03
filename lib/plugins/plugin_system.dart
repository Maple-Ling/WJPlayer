/// 插件系统对外统一入口（barrel）。
///
/// 在 main() 中（创建 ProviderContainer 后、runApp 之前）调用
/// [initializePluginSystem] 完成初始化。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/app_logger.dart';
import 'manager/plugin_manager.dart';
import 'runtime/plugin_host_bindings.dart';
import 'runtime/plugin_ui_host.dart';

export 'manager/plugin_manager.dart';
export 'manager/plugin_extension_registry.dart';
export 'models/plugin_extension_point.dart';
export 'models/plugin_info.dart';
export 'models/plugin_manifest.dart';
export 'models/plugin_permission.dart';
export 'providers/plugin_providers.dart';
export 'runtime/plugin_host_bindings.dart';
export 'runtime/plugin_player_bridge.dart';
export 'ui/plugin_management_screen.dart';

/// 初始化插件系统：
///  1. 绑定 ProviderContainer（供 ctx.emby / player 读取应用状态）；
///  2. 扫描已安装插件并激活已启用项；
///  3. 把扩展注册表交给 UI 宿主（用于 openPage）。
///
/// 插件加载失败不会抛出，确保不影响应用启动。
Future<void> initializePluginSystem(ProviderContainer container) async {
  PluginHostBindings.instance.container = container;
  try {
    final manager = await PluginManager.ensureInitialized();
    PluginUiHost.registry = manager.registry;
    AppLogger().i('PluginSystem', '插件系统已就绪，已加载 ${manager.plugins.length} 个插件');
  } catch (e, st) {
    AppLogger().eWithStack('PluginSystem', '插件系统初始化失败（已忽略）', e, st);
  }
}

/// 注册当前平台导航器（用于插件 UI：Toast/Dialog/openPage）。
void attachPluginNavigator(GlobalKey<NavigatorState> key) {
  PluginHostBindings.instance.navigatorKey = key;
}
