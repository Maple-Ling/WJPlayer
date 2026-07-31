import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/server_providers.dart';
import '../manager/plugin_manager.dart';
import '../models/plugin_extension_point.dart';
import '../providers/plugin_providers.dart';

/// 渲染插件注册的「首页统计指标」（homeStats 扩展点）。
///
/// 放在首页媒体计数（电影/剧集/总共）旁边。每个 homeStats 扩展的 handler 返回：
///   { label, value }                         // 单个指标
///   { metrics: [{label, value}, ...] }        // 多个指标
/// 本组件按宿主统一样式渲染，并在每个指标前加一条分隔线。
///
/// 数据按扩展缓存（避免每次重建都重新请求）；扩展集合变化时刷新。
class PluginHomeStatsView extends ConsumerStatefulWidget {
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;
  final Color dividerColor;
  final double dividerHeight;

  const PluginHomeStatsView({
    super.key,
    required this.labelStyle,
    required this.valueStyle,
    required this.dividerColor,
    this.dividerHeight = 28,
  });

  @override
  ConsumerState<PluginHomeStatsView> createState() =>
      _PluginHomeStatsViewState();
}

class _PluginHomeStatsViewState extends ConsumerState<PluginHomeStatsView> {
  final Map<String, Future<dynamic>> _cache = {};

  /// 当前服务器 id（纳入缓存键的作用域）。在 build 中更新。
  String _serverScope = '';

  /// 缓存键：当前服务器 id + 扩展键 + handler 句柄 id。
  /// - handler id：插件重新注册（如保存设置后）会生成新的 id → 自动重新请求。
  /// - 服务器 id：很多 homeStats 是「按当前服务器」计算的（如只在某台服显示的流量
  ///   统计）。不纳入作用域的话，切服后会沿用上一台服的旧结果（如切走 uhdnow 后仍
  ///   显示流量）。把它纳入键 → 切服即重算，handler 返回空则该指标隐藏。
  String _cacheKey(PluginExtension ext) {
    final h = ext.data['handler'];
    final hid = (h is Map) ? '${h['__handler__'] ?? ''}' : '$h';
    return '$_serverScope::${ext.key}:$hid';
  }

  Future<dynamic> _futureFor(PluginExtension ext) {
    return _cache.putIfAbsent(
      _cacheKey(ext),
      () => PluginManager.instance.triggerExtension(ext),
    );
  }

  /// 把 handler 返回值规整为 [{label, value}] 列表。
  List<MapEntry<String, String>> _normalize(dynamic data) {
    final out = <MapEntry<String, String>>[];
    void addOne(dynamic m) {
      if (m is Map && m['value'] != null) {
        out.add(MapEntry('${m['label'] ?? ''}', '${m['value']}'));
      }
    }

    if (data is Map && data['metrics'] is List) {
      for (final m in data['metrics']) {
        addOne(m);
      }
    } else if (data is List) {
      for (final m in data) {
        addOne(m);
      }
    } else {
      addOne(data);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // 监听注册表：扩展增减时重建（并清理失效缓存）。
    ref.watch(pluginRegistryProvider);
    // 监听当前服务器：切服时把它纳入缓存作用域，触发按服务器统计的指标重算。
    _serverScope =
        ref.watch(currentServerProvider.select((s) => s?.id)) ?? '';
    final exts = PluginManager.instance.registry
        .byType(PluginExtensionType.homeStats);

    if (exts.isEmpty) {
      _cache.clear();
      return const SizedBox.shrink();
    }

    // 清理已移除/已重注册扩展的缓存。
    final liveKeys = exts.map(_cacheKey).toSet();
    _cache.removeWhere((k, _) => !liveKeys.contains(k));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final ext in exts)
          FutureBuilder<dynamic>(
            future: _futureFor(ext),
            builder: (context, snap) {
              final metrics = snap.hasData
                  ? _normalize(snap.data)
                  : <MapEntry<String, String>>[];
              if (snap.connectionState == ConnectionState.waiting) {
                return _metricGroup(
                    [MapEntry(ext.title ?? '插件', '...')]);
              }
              if (metrics.isEmpty) return const SizedBox.shrink();
              return _metricGroup(metrics);
            },
          ),
      ],
    );
  }

  Widget _metricGroup(List<MapEntry<String, String>> metrics) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final m in metrics) ...[
          _divider(),
          _metric(m.key, m.value),
        ],
      ],
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: widget.dividerHeight,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: widget.dividerColor,
      );

  Widget _metric(String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 76),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: widget.labelStyle),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: widget.valueStyle,
          ),
        ],
      ),
    );
  }
}
