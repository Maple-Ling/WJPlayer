import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../manager/plugin_extension_registry.dart';
import '../manager/plugin_manager.dart';

/// 插件管理器（已在启动时初始化的全局单例）。
///
/// 使用 ChangeNotifierProvider 以便 UI 随 notifyListeners 重建；
/// 这里不创建实例，只引用已初始化的单例。
final pluginManagerProvider = ChangeNotifierProvider<PluginManager>((ref) {
  return PluginManager.instance;
});

/// 扩展点注册表（供各端 UI 读取并渲染扩展）。
final pluginRegistryProvider =
    ChangeNotifierProvider<PluginExtensionRegistry>((ref) {
  return PluginManager.instance.registry;
});
