import 'package:flutter/foundation.dart';

import '../../core/services/app_logger.dart';
import '../../core/utils/platform_utils.dart';
import '../models/plugin_extension_point.dart';

/// 收集所有插件注册的扩展点，供主程序在对应位置渲染/触发。
///
/// 这是「主程序侧」的扩展点收集与桥接中心：UI 通过监听本注册表，
/// 实时拿到 sidebarItems / actions / settingsPages 等扩展并渲染。
class PluginExtensionRegistry extends ChangeNotifier {
  static final AppLogger _log = AppLogger();

  final List<PluginExtension> _extensions = [];

  /// 当前运行平台。
  static PluginPlatform get currentPlatform {
    if (isTvPlatform) return PluginPlatform.tv;
    if (isDesktopPlatform) return PluginPlatform.desktop;
    return PluginPlatform.mobile;
  }

  /// 按类型获取（已按平台过滤，调用方无需再判断）。
  List<PluginExtension> byType(PluginExtensionType type) =>
      _extensions.where((e) => e.type == type).toList(growable: false);

  /// 注册一个扩展。若当前平台不支持该扩展点，则忽略并记录日志。
  ///
  /// 返回 true 表示已注册；false 表示被平台过滤忽略。
  bool register(PluginExtension ext) {
    if (!PluginExtensionSupport.isSupported(ext.type, currentPlatform)) {
      _log.i(
        'PluginExt',
        '忽略扩展点：${ext.pluginId} 的 ${ext.type.id} 在 ${currentPlatform.name} 平台不支持',
      );
      return false;
    }
    // 同 key 去重（覆盖）。
    _extensions.removeWhere((e) => e.key == ext.key);
    _extensions.add(ext);
    notifyListeners();
    return true;
  }

  void unregister(String pluginId, PluginExtensionType type, String id) {
    final key = '$pluginId::${type.id}::$id';
    final before = _extensions.length;
    _extensions.removeWhere((e) => e.key == key);
    if (_extensions.length != before) notifyListeners();
  }

  /// 移除某插件的全部扩展（卸载/禁用时调用）。
  void removeAllForPlugin(String pluginId) {
    final before = _extensions.length;
    _extensions.removeWhere((e) => e.pluginId == pluginId);
    if (_extensions.length != before) notifyListeners();
  }
}
