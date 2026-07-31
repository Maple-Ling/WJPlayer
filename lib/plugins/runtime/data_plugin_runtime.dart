import 'dart:async';

import '../../core/services/app_logger.dart';
import '../manager/plugin_extension_registry.dart';
import '../models/plugin_extension_point.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_permission.dart';
import 'plugin_context_bridge.dart';
import 'plugin_declarative_common.dart';
import 'plugin_player_bridge.dart';
import 'plugin_runtime_base.dart';
import 'plugin_storage.dart';

/// runtime=data —— 声明式数据驱动插件（iOS App Store 合规，无可执行代码）。
///
/// 读取 manifest 的 `data` 块，用宿主内置的固定解释器执行：
///  - `homeStats`：请求 + JSON 点路径映射 → 首页指标；
///  - `onEvent`：播放事件触发请求（如播完发通知）；
///  - `settings`：声明式配置字段，复用现有设置页宿主，存到插件 storage 的 `__cfg__`。
///
/// 所有 HTTP 都经 [PluginContextBridge]（HTTPS + 白名单 + 权限门控），与 JS 插件同一套安全模型。
class DataPluginRuntime implements PluginRuntimeBase {
  static final AppLogger _log = AppLogger();

  static const _kHomeStats = '__data_homeStats__';
  static const _kSettingsLoad = '__data_settings_load__';
  static const _kSettingsSubmit = '__data_settings_submit__';

  final PluginManifest manifest;
  final PluginContextBridge bridge;
  final PluginStorage storage;
  final PluginGrantedPermissions permissions;
  final PluginExtensionRegistry registry;

  late final Map<String, dynamic> _data;
  StreamSubscription<PluginPlayerEvent>? _playerSub;
  bool _disposed = false;

  DataPluginRuntime({
    required this.manifest,
    required this.bridge,
    required this.storage,
    required this.permissions,
    required this.registry,
  }) {
    final raw = manifest.raw['data'];
    _data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  @override
  String get pluginId => manifest.id;
  @override
  bool get isFaulted => false;

  @override
  Future<void> load() async {
    if (_data['homeStats'] is Map) {
      registry.register(PluginExtension(
        pluginId: manifest.id,
        type: PluginExtensionType.homeStats,
        id: 'data_homeStats',
        data: {
          'id': 'data_homeStats',
          'title': manifest.name,
          'handler': {'__handler__': _kHomeStats},
        },
        fromManifest: true,
      ));
    }

    final settings = _data['settings'];
    if (settings is List && settings.isNotEmpty) {
      registry.register(PluginExtension(
        pluginId: manifest.id,
        type: PluginExtensionType.settingsPages,
        id: 'data_settings',
        data: {
          'id': 'data_settings',
          'title': '${manifest.name} 设置',
          // PluginSettingsPageHost 直接渲染这些字段，并用下面的 load/submit 存取。
          'fields': [
            for (final s in settings)
              if (s is Map)
                {
                  'key': '${s['key']}',
                  'label': '${s['label'] ?? s['key']}',
                  'type': '${s['type'] ?? 'text'}',
                  if (s['default'] != null) 'default': s['default'],
                  if (s['hint'] != null) 'hint': '${s['hint']}',
                },
          ],
          'load': {'__handler__': _kSettingsLoad},
          'submit': {'__handler__': _kSettingsSubmit},
        },
        fromManifest: true,
      ));
    }

    if (_data['onEvent'] is List &&
        permissions.has(PluginPermissions.playerRead.id)) {
      _playerSub =
          PluginPlayerBridge.instance.events.listen((e) => _onPlayerEvent(e));
    }
  }

  @override
  Future<dynamic> invokeHandler(String handlerId, List<dynamic> args) async {
    if (_disposed) return null;
    switch (handlerId) {
      case _kHomeStats:
        return _runHomeStats();
      case _kSettingsLoad:
        final cfg = await storage.get('__cfg__');
        return cfg is Map ? cfg : <String, dynamic>{};
      case _kSettingsSubmit:
        final values = args.isNotEmpty && args[0] is Map ? args[0] as Map : {};
        await storage.set('__cfg__', Map<String, dynamic>.from(values));
        return null;
    }
    return null;
  }

  @override
  Future<dynamic> invokeNamed(String fnName, List<dynamic> args) async => null;

  Future<Map<String, dynamic>> _vars(
      {Map? media, bool serverUrl = false}) async {
    final cfg = await storage.get('__cfg__');
    final vars = <String, dynamic>{'cfg': cfg is Map ? cfg : <String, dynamic>{}};
    if (media != null) vars['media'] = media;
    if (serverUrl) vars['serverUrl'] = await currentServerUrl(bridge);
    return vars;
  }

  Future<dynamic> _runHomeStats() async {
    final hs = _data['homeStats'];
    if (hs is! Map) return {'metrics': <dynamic>[]};
    final vars = await _vars(serverUrl: true);

    final when = hs['when'];
    if (when is Map && when['serverUrlIncludes'] is String) {
      final s = '${vars['serverUrl']}'.toLowerCase();
      if (!s.contains('${when['serverUrlIncludes']}'.toLowerCase())) {
        return {'metrics': <dynamic>[]}; // 未命中门槛：不显示
      }
    }

    // 多步：依次请求，把 capture 的响应字段存进 vars 供后续 step / 指标使用；
    // 或单步 request（旧式）。最后一次响应体供指标 path 取值。
    dynamic lastBody;
    final steps = hs['steps'];
    if (steps is List) {
      for (final step in steps) {
        if (step is! Map || step['request'] is! Map) continue;
        final res = await declRequest(bridge, step['request'] as Map, vars);
        lastBody = res?['body'];
        final cap = step['capture'];
        if (cap is Map) {
          cap.forEach((k, path) => vars['$k'] = jsonPath(lastBody, '$path'));
        }
      }
    } else if (hs['request'] is Map) {
      final res = await declRequest(bridge, hs['request'] as Map, vars);
      lastBody = res?['body'];
    } else {
      return {'metrics': <dynamic>[]};
    }

    final metrics = <Map<String, dynamic>>[];
    final defs = hs['metrics'];
    if (defs is List) {
      for (final d in defs) {
        if (d is! Map) continue;
        final String val;
        if (d.containsKey('value')) {
          val = resolveValue(d['value'], vars, lastBody);
        } else {
          final v = jsonPath(lastBody, '${d['path']}');
          final suffix = d['suffix'] == null ? '' : '${d['suffix']}';
          val = v == null ? '—' : '$v$suffix';
        }
        metrics.add({'label': '${d['label']}', 'value': val});
      }
    }
    return {'metrics': metrics};
  }

  Future<void> _onPlayerEvent(PluginPlayerEvent event) async {
    if (_disposed) return;
    final list = _data['onEvent'];
    if (list is! List) return;
    for (final e in list) {
      if (e is! Map || '${e['event']}' != event.type) continue;
      final req = e['request'];
      if (req is! Map) continue;
      try {
        await declRequest(bridge, req, await _vars(media: event.data));
      } catch (err) {
        _log.w('DataPlugin', '[$pluginId] onEvent(${event.type}) 失败: $err');
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _playerSub?.cancel();
    _playerSub = null;
    bridge.dispose();
  }
}
