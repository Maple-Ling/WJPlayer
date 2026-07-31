import 'dart:async';

import '../manager/plugin_extension_registry.dart';
import '../models/plugin_extension_point.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_permission.dart';
import 'plugin_context_bridge.dart';
import 'plugin_declarative_common.dart';
import 'plugin_runtime_base.dart';

/// runtime=addon —— 远程 addon 服务插件（Stremio/Forward 模型，iOS App Store 合规）。
///
/// 插件逻辑跑在远程 HTTP 服务（如部署在 oauth-proxy 的 Pages Functions）上，
/// App 只按固定协议收发 JSON，设备上不下载/执行任何代码。
///
/// 协议（v1）：
///   GET {baseUrl}/homeStats?serverUrl=..  -> { metrics: [ { label, value } ] }
///   （catalog/meta/stream 待宿主媒体源渲染接入后启用。）
///
/// HTTP 经 [PluginContextBridge]，故 `addon.baseUrl` 的 host 必须在 manifest
/// `httpAllowedHosts` 白名单内，安全模型与其它插件一致。
class AddonPluginRuntime implements PluginRuntimeBase {
  static const _kHomeStats = '__addon_homeStats__';

  final PluginManifest manifest;
  final PluginContextBridge bridge;
  final PluginGrantedPermissions permissions;
  final PluginExtensionRegistry registry;

  late final String _baseUrl;
  late final List<String> _resources;
  bool _disposed = false;

  AddonPluginRuntime({
    required this.manifest,
    required this.bridge,
    required this.permissions,
    required this.registry,
  }) {
    final addon = manifest.raw['addon'];
    _baseUrl = (addon is Map ? '${addon['baseUrl'] ?? ''}' : '')
        .replaceAll(RegExp(r'/+$'), '');
    final res = addon is Map ? addon['resources'] : null;
    _resources = res is List ? res.map((e) => '$e').toList() : const [];
  }

  @override
  String get pluginId => manifest.id;
  @override
  bool get isFaulted => false;

  @override
  Future<void> load() async {
    if (_baseUrl.isEmpty) return;
    if (_resources.contains('homeStats')) {
      registry.register(PluginExtension(
        pluginId: manifest.id,
        type: PluginExtensionType.homeStats,
        id: 'addon_homeStats',
        data: {
          'id': 'addon_homeStats',
          'title': manifest.name,
          'handler': {'__handler__': _kHomeStats},
        },
        fromManifest: true,
      ));
    }
    // catalog/meta/stream：待宿主媒体源渲染接入后，在此注册 mediaSources 扩展。
  }

  @override
  Future<dynamic> invokeHandler(String handlerId, List<dynamic> args) async {
    if (_disposed || _baseUrl.isEmpty) return null;
    if (handlerId == _kHomeStats) {
      final serverUrl = await currentServerUrl(bridge);
      final res = await declRequest(bridge, {
        'method': 'GET',
        'url': '$_baseUrl/homeStats',
        'query': {'serverUrl': serverUrl},
      }, const {});
      final body = res?['body'];
      if (body is Map && body['metrics'] is List) {
        return {'metrics': body['metrics']};
      }
      return {'metrics': <dynamic>[]};
    }
    return null;
  }

  @override
  Future<dynamic> invokeNamed(String fnName, List<dynamic> args) async => null;

  @override
  Future<void> dispose() async {
    _disposed = true;
    bridge.dispose();
  }
}
