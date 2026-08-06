import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/media_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/providers/watch_history_providers.dart';
import '../../../core/services/watch_history/watch_history_models.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/media_source_backend.dart';
// SourcePlayback is no longer used; resume flows through unified detail.
import '../../../core/sources/unified_media_adapter.dart';
import '../source/unified_media_screens.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/media_widgets.dart';

final watchHistoryRefreshProvider = StateProvider<int>((ref) => 0);
final allWatchHistoryProvider =
    FutureProvider<List<WatchHistoryRecord>>((ref) async {
  ref.watch(watchHistoryRefreshProvider);
  return ref.watch(watchHistoryProvider).loadAll();
});

/// 飞牛封面需要 Authorization/Cookie/Authx；按服务器缓存请求头，避免记录列表每张卡
/// 都重复登录或发签名请求。非飞牛/取头失败时返回 null，卡片自动退回占位图。
final historyFeiniuImageHeadersProvider = FutureProvider.autoDispose
    .family<Map<String, String>?, String>((ref, serverId) async {
  final server = ref
      .watch(serverListProvider)
      .where((entry) => entry.id == serverId)
      .firstOrNull;
  if (server == null || server.sourceKind != SourceKind.feiniu) return null;
  try {
    return await FeiniuBackend().imageHeaders(server);
  } catch (_) {
    return null;
  }
});

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final Set<String> _selectedIds = {};
  bool get _selecting => _selectedIds.isNotEmpty;
  bool _hasRefreshed = false;

  @override
  void initState() {
    super.initState();
    // 进入页面自动触发一次刷新
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasRefreshed) {
        _hasRefreshed = true;
        ref.read(watchHistoryRefreshProvider.notifier).state++;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 从其他页面返回时再次刷新
    if (!_hasRefreshed) {
      _hasRefreshed = true;
      ref.read(watchHistoryRefreshProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(allWatchHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(_selecting ? '已选 ${_selectedIds.length}' : '播放记录'),
        actions: [
          if (_selecting) ...[
            TextButton(onPressed: _selectAll, child: const Text('全选')),
            IconButton(tooltip: '删除所选', onPressed: _deleteSelected, icon: const Icon(Icons.delete_rounded)),
            IconButton(tooltip: '取消多选', onPressed: () => setState(_selectedIds.clear), icon: const Icon(Icons.close_rounded)),
          ] else IconButton(
            tooltip: '刷新记录',
            onPressed: () =>
                ref.read(watchHistoryRefreshProvider.notifier).state++,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(watchHistoryRefreshProvider.notifier).state++;
          await ref.read(allWatchHistoryProvider.future);
        },
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const _HistoryEmpty(text: '记录加载失败，下拉重试'),
          data: (items) => items.isEmpty
              ? const _HistoryEmpty(text: '播放后会自动记录在这里')
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                      12, 8, 12, 20 + MediaQuery.paddingOf(context).bottom),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final record = items[index];
                    return Dismissible(
                      key: ValueKey(record.recordId),
                      direction: _selecting ? DismissDirection.none : DismissDirection.endToStart,
                      background: Container(color: Theme.of(context).colorScheme.errorContainer, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_rounded)),
                      onDismissed: (_) => _deleteOne(record.recordId),
                      child: _HistoryTile(
                        record: record,
                        selected: _selectedIds.contains(record.recordId),
                        onLongPress: () => setState(() => _selectedIds.add(record.recordId)),
                        onTap: _selecting ? () => setState(() { _selectedIds.contains(record.recordId) ? _selectedIds.remove(record.recordId) : _selectedIds.add(record.recordId); }) : null,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _selectAll() async {
    final items = await ref.read(allWatchHistoryProvider.future);
    if (!mounted) return;
    setState(() { _selectedIds..clear()..addAll(items.map((e) => e.recordId)); });
  }
  Future<void> _deleteOne(String id) async {
    await ref.read(watchHistoryProvider).deleteRecord(id);
    ref.read(watchHistoryRefreshProvider.notifier).state++;
  }
  Future<void> _deleteSelected() async {
    for (final id in _selectedIds.toList()) { await ref.read(watchHistoryProvider).deleteRecord(id); }
    if (!mounted) return;
    setState(_selectedIds.clear);
    ref.read(watchHistoryRefreshProvider.notifier).state++;
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.record, this.selected = false, this.onTap, this.onLongPress});
  final WatchHistoryRecord record;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverId = record.scopeKey.split(':').first;
    final server = ref
        .watch(serverListProvider)
        .where((s) => s.id == serverId)
        .firstOrNull;
    final sourceHeaders = server?.sourceKind == SourceKind.feiniu
        ? ref.watch(historyFeiniuImageHeadersProvider(serverId)).asData?.value
        : null;
    final runtime = record.runTimeTicks ?? 0;
    final progress = runtime > 0
        ? (record.lastPositionTicks / runtime).clamp(0.0, 1.0)
        : 0.0;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap ?? (server == null ? null : () => _openDetail(context, ref, server)),
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 88,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: record.sourcePosterUrl?.isNotEmpty == true
                      ? MediaImage(
                          imageUrl: record.sourcePosterUrl,
                          httpHeaders: sourceHeaders,
                          fit: BoxFit.cover,
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer,
                          ),
                          child: Icon(
                            record.mediaKind == WatchHistoryMediaKind.episode
                                ? Icons.tv_rounded
                                : Icons.movie_rounded,
                            size: 30,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_title(record),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      server?.name ?? '服务器已移除',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_duration(record.lastPositionTicks)} / ${_duration(runtime)} · ${_relative(record.lastPlayedAt)}',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '搜索所有媒体库',
                icon: const Icon(Icons.travel_explore_rounded),
                onPressed: () => _searchAllLibraries(context, ref),
              ),
              IconButton(
                tooltip: '播放',
                onPressed: server == null ? null : () => _resume(context, ref, server),
                icon: Icon(Icons.play_circle_fill_rounded,
                    color: server == null
                        ? Theme.of(context).disabledColor
                        : Theme.of(context).colorScheme.primary,
                    size: 34),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 导航防抖（const widget 类内只能放 static 可变状态）。
  static bool _navInFlight = false;

  Future<void> _openDetail(
      BuildContext context, WidgetRef ref, ServerConfig server) async {
    if (_navInFlight) return;
    _navInFlight = true;
    try {
      ref.read(currentServerProvider.notifier).state = server;
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
      final isEpisode = record.mediaKind == WatchHistoryMediaKind.episode;
      // 进入"剧集/电影"详情：优先序列(id)，保证飞牛按正确类型拉取完整详情（季/集/演员/剧照）。
      final targetId = server.sourceKind == SourceKind.feiniu
          ? (record.seriesEntryId ?? record.sourceEntryId) ?? record.mediaPath
          : (isEpisode
                  ? record.seriesEntryId
                  : record.lastEmbyItemId);
      if (targetId == null || targetId.isEmpty) {
        AppToast.show(context, '该记录缺少可打开的资源标识', kind: AppToastKind.error);
        return;
      }
      // 直接使用影视详情页整体 UI（真实类型 entry），飞牛/emby 保持一致。
      // 经 go_router 统一路由（extra 携带真实服务器+entry），避免手动
      // Navigator.push 与 StatefulShellRoute 混用导致播放器退出后灰屏。
      if (!context.mounted) return;
      await context.push(
        '/detail/${Uri.encodeComponent(targetId!)}',
        extra: UnifiedMediaDetailRouteExtra(
          server: server,
          entry: UnifiedMediaEntry(
            id: targetId!,
            name: record.title,
            type: isEpisode ? 'Series' : 'Movie',
            posterUrl: record.sourcePosterUrl,
          ),
        ),
      );
    } finally {
      _navInFlight = false;
    }
  }

  Future<void> _resume(
      BuildContext context, WidgetRef ref, ServerConfig server) async {
    if (_navInFlight) return;
    _navInFlight = true;
    try {
      ref.read(currentServerProvider.notifier).state = server;
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
      String? id;
      if (server.sourceKind == SourceKind.feiniu) {
        final stableId = record.sourceEntryId ?? record.mediaPath;
        if (stableId != null && stableId.isNotEmpty) {
          id = stableId;
        } else {
          try {
            final entry = (await FeiniuBackend().search(server, record.title))
                .where((e) => !e.isDir && e.isVideo)
                .firstOrNull;
            if (!context.mounted) return;
            if (entry == null) throw StateError('not found');
            id = entry.id;
          } catch (_) {
            if (context.mounted) {
              AppToast.show(context, '${server.name}中未找到对应资源',
                  kind: AppToastKind.error);
            }
            return;
          }
        }
      } else {
        id = record.lastEmbyItemId;
      }
      if (id == null || id.isEmpty) {
        AppToast.show(context, '该记录缺少可恢复的资源标识', kind: AppToastKind.error);
        return;
      }
      // 经 go_router 统一路由打开详情页（真实服务器+entry），与 _openDetail 一致。
      if (!context.mounted) return;
      await context.push(
        '/detail/${Uri.encodeComponent(id!)}',
        extra: UnifiedMediaDetailRouteExtra(
          server: server,
          entry: UnifiedMediaEntry(
            id: id!,
            name: record.title,
            type: server.sourceKind == SourceKind.feiniu ? 'Movie' : 'Series',
            posterUrl: record.sourcePosterUrl,
          ),
          autoPlay: true,
        ),
      );
    } finally {
      _navInFlight = false;
    }
  }

  void _searchAllLibraries(BuildContext context, WidgetRef ref) {
    ref.read(aggregateSearchProvider.notifier).state = true;
    ref.read(searchQueryProvider.notifier).state =
        record.seriesTitle?.trim().isNotEmpty == true
            ? record.seriesTitle!.trim()
            : record.title;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) context.push('/search');
    });
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除播放记录'),
        content: Text('删除“${_title(record)}”的本地记录？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(watchHistoryProvider).deleteRecord(record.recordId);
    ref.read(watchHistoryRefreshProvider.notifier).state++;
  }

  static String _title(WatchHistoryRecord r) {
    if (r.mediaKind != WatchHistoryMediaKind.episode) return r.title;
    final season = r.seasonNumber?.toString().padLeft(2, '0') ?? '--';
    final episode = r.episodeNumber?.toString().padLeft(2, '0') ?? '--';
    return '${r.seriesTitle ?? r.title}  S${season}E$episode';
  }

  static String _duration(int ticks) {
    if (ticks <= 0) return '--:--';
    final seconds = ticks ~/ 10000000;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return h > 0
        ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _relative(DateTime time) {
    final delta = DateTime.now().toUtc().difference(time.toUtc());
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
    if (delta.inDays < 1) return '${delta.inHours} 小时前';
    if (delta.inDays < 30) return '${delta.inDays} 天前';
    return '${time.toLocal().year}-${time.toLocal().month.toString().padLeft(2, '0')}-${time.toLocal().day.toString().padLeft(2, '0')}';
  }
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
        const Icon(Icons.history_rounded, size: 60),
        const SizedBox(height: 12),
        Center(child: Text(text)),
      ],
    );
  }
}
