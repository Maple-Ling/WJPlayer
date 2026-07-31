part of 'settings_screen.dart';

/// 跨服聚合设置页（移动端 + 桌面端共用）。
///
/// 集/电影详情页会聚合展示同一内容在其它 Emby 服务器上的所有版本；这里按服务器控制
/// 是否参与聚合——开为允许、关为不允许（默认全部允许）。状态存于
/// [aggregationDisabledServersProvider]。
class AggregationSettingsScreen extends ConsumerWidget {
  const AggregationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(aggregationDisabledServersProvider); // 状态变更时重建
    final notifier = ref.read(aggregationDisabledServersProvider.notifier);
    final servers =
        ref.watch(serverListProvider).where((s) => !s.isFileBrowse).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('跨服聚合')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              '在集 / 电影详情页聚合展示同一内容在其它服务器上的所有版本。'
              '这里选择哪些服务器参与聚合：开为允许，关为不允许。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          if (servers.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.dns_outlined),
                title: Text('暂无 Emby 服务器'),
                subtitle: Text('添加并登录 Emby 服务器后可在此设置'),
              ),
            )
          else
            for (final s in servers)
              Card(
                child: TdSwitchTile(
                  secondary: const Icon(Icons.dns_outlined),
                  title: Text(s.name),
                  subtitle:
                      Text(notifier.isEnabled(s.id) ? '参与聚合' : '不参与聚合'),
                  value: notifier.isEnabled(s.id),
                  onChanged: (v) => notifier.setEnabled(s.id, v),
                ),
              ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '说明：聚合匹配优先使用 TMDB / 外部 id 精确反查，其次用片名与季集号，'
              '因此不同服务器上的同一内容也能对齐。关闭的服务器不会被查询。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
