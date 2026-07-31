import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/plugin_providers.dart';
import '../store/plugin_store.dart';
import '../../ui/widgets/common/app_toast.dart';

/// 插件市场页（移动端 + 桌面共用）。从仓库 registry.json 拉取可安装插件，
/// 一键网络安装——解决 iOS 无法用文件选择器导入 .ipk 的问题，也方便桌面安装。
class PluginStoreScreen extends ConsumerStatefulWidget {
  const PluginStoreScreen({super.key, required this.target});

  /// 当前平台目标（'pc' / 'mobile' / 'tv'），用于过滤仓库里适配本平台的插件。
  final String target;

  @override
  ConsumerState<PluginStoreScreen> createState() => _PluginStoreScreenState();
}

class _PluginStoreScreenState extends ConsumerState<PluginStoreScreen> {
  late Future<List<StorePlugin>> _future;
  final Set<String> _installing = {};

  @override
  void initState() {
    super.initState();
    _future = PluginStore.fetchRegistry();
  }

  void _reload() {
    setState(() => _future = PluginStore.fetchRegistry());
  }

  Future<void> _install(StorePlugin plugin) async {
    final url = plugin.packageUrl;
    if (url == null) return;
    setState(() => _installing.add(plugin.id));
    try {
      final info = await ref.read(pluginManagerProvider).installFromUrl(url);
      if (mounted) {
        AppToast.show(context, '已安装 ${info.name}，请到「插件」列表中启用');
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '安装失败: $e', kind: AppToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _installing.remove(plugin.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(pluginManagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件市场'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<List<StorePlugin>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorState(error: '${snap.error}', onRetry: _reload);
          }
          final list = (snap.data ?? const [])
              .where((p) => p.packageUrl != null && p.supports(widget.target))
              .toList(growable: false);
          if (list.isEmpty) {
            return const Center(child: Text('仓库暂无适配本平台的插件'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final plugin = list[i];
              return _StoreTile(
                plugin: plugin,
                installedVersion: manager.pluginById(plugin.id)?.version,
                installing: _installing.contains(plugin.id),
                onInstall: () => _install(plugin),
              );
            },
          );
        },
      ),
    );
  }
}

class _StoreTile extends StatelessWidget {
  final StorePlugin plugin;
  final String? installedVersion;
  final bool installing;
  final VoidCallback onInstall;

  const _StoreTile({
    required this.plugin,
    required this.installedVersion,
    required this.installing,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final isInstalled = installedVersion != null;
    final isSameVersion = installedVersion == plugin.version;
    final String label;
    if (installing) {
      label = '安装中';
    } else if (isInstalled && isSameVersion) {
      label = '已安装';
    } else if (isInstalled) {
      label = '更新到 v${plugin.version}';
    } else {
      label = '安装';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.extension, color: Color(0xFF5B8DEF)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plugin.name,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'v${plugin.version ?? '?'}'
                        '${plugin.author.isNotEmpty ? ' · ${plugin.author}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (installing)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  FilledButton.tonal(
                    onPressed:
                        (isInstalled && isSameVersion) ? null : onInstall,
                    child: Text(label),
                  ),
              ],
            ),
            if (plugin.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(plugin.description,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('加载插件市场失败'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
