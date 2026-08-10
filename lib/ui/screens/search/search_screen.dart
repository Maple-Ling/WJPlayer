import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/services/tv_focus_manager.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/platform_utils.dart';
import '../source/unified_media_screens.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/server_group_header.dart';
import '../../widgets/common/tv_focusable.dart';
import '../../widgets/common/tv_focus_widgets.dart';

/// 搜索页（含聚合搜索）
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  bool _showResults = false;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(searchQueryProvider).trim();
    if (initial.isNotEmpty) {
      _searchController.text = initial;
      _showResults = true;
    }
  }
  
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final isAggregate = ref.watch(aggregateSearchProvider);
    final searchResults = ref.watch(searchResultsProvider);
    final searchHistory = ref.watch(searchHistoryProvider);
    final server = ref.watch(currentServerProvider);
    // 区域 count 计算（结果模式：2 头部元素 + 结果条目）：
    //  - 聚合：头部(2) + 每个服务器组一行（FocusSectionLayout）
    //  - 普通/飞牛单列表：2 + 结果条数（线性）
    //  - 历史/空态：2
    FocusSectionLayout? aggLayout;
    var linearCount = 2;
    var isAggregateResults = false;
    var isHistoryChips = false;
    if (_showResults && isAggregate) {
      final aggData = ref.watch(aggregateSearchResultsProvider).asData?.value ??
          const <String, List<MediaItem>>{};
      final feiniuGroups =
          ref.watch(aggregateFeiniuSearchProvider(ref.watch(searchQueryProvider)))
                  .asData?.value ??
              const <FeiniuSearchGroup>[];
      if (aggData.isNotEmpty || feiniuGroups.isNotEmpty) {
        isAggregateResults = true;
        final sections = <FocusSection>[
          const FocusSection('head', 2),
          for (final group in aggData.entries)
            FocusSection('agg_${group.key}', group.value.length),
          for (var i = 0; i < feiniuGroups.length; i++)
            FocusSection('feiniu_$i', feiniuGroups[i].entries.length),
        ];
        aggLayout = FocusSectionLayout(sections);
      }
    } else if (_showResults && !isAggregate) {
      final isFeiniu = server != null && server.sourceKind == SourceKind.feiniu;
      final n = isFeiniu
          ? (ref
                      .watch(feiniuSearchResultsProvider((
                    serverId: server.id,
                    query: ref.watch(searchQueryProvider),
                  )))
                      .asData
                      ?.value
                      ?.length ??
                  0)
          : (searchResults.asData?.value?.length ?? 0);
      linearCount = 2 + n;
    } else if (!_showResults && searchHistory.isNotEmpty) {
      // 搜索历史 chips 模式：2 头部元素 + 历史条数（线性全方向移动）。
      isHistoryChips = true;
      linearCount = 2 + searchHistory.length;
    }

    // TV：注册焦点区域（0=搜索框、1=聚合开关、2..=结果条目），方向键
    // 边界 → 状态栏；返回键放行系统默认（逐级后退/分支根返回回影视 tab）。
    final tvAreaReady = isTvPlatform;
    return PopScope(
      canPop: true, // 不拦截返回：手机/电视一致走系统返回。
      child: tvAreaReady
          ? TvFocusArea(
              id: 'search',
              count: aggLayout?.totalCount ?? linearCount,
              // 结果条目：聚合用 FocusSectionLayout（服务器组横排 + 屏幕
              // 视觉对齐）；单列表线性下移；头部两元素左右移动。
              traversal: aggLayout != null
                  ? aggLayout.traversal
                  : isHistoryChips
                      ? _chipsTraversal(linearCount)
                      : _resultsTraversal(linearCount),
              onBoundary: (_) =>
                  TvFocusManager.instance.enterArea('main_tabs'),
              // Builder 保证取焦点节点时区域已注册。
              child: Builder(
                builder: (ctx) => _buildScaffold(
                  ctx,
                  isAggregate: isAggregate,
                  searchResults: searchResults,
                  searchHistory: searchHistory,
                  resultOffset: aggLayout == null ? 2 : null,
                  aggLayout: aggLayout,
                  isAggregateResults: isAggregateResults,
                ),
              ),
            )
          : _buildScaffold(
              context,
              isAggregate: isAggregate,
              searchResults: searchResults,
              searchHistory: searchHistory,
            ),
    );
  }

  /// 单列结果遍历：0=搜索框、1=聚合开关、2..=结果条目。
  /// 结果条目上下线性移动、左右停留；顶部/底部边界 → 状态栏。
  TraversalFn _resultsTraversal(int count) {
    return (current, direction, _) {
      switch (direction) {
        case DPad.up:
          if (current > 1) return current - 1;
          if (current == 1) return 0;
          return -1;
        case DPad.down:
          if (current < count - 1) return current + 1;
          return -1;
        case DPad.left:
          return current == 1 ? 0 : current;
        case DPad.right:
          return current == 0 ? 1 : current;
      }
    };
  }

  /// 搜索历史 chips 遍历：全方向线性（chips 在 Wrap 流式排布，上下/左右
  /// 均逐项移动）；边界 → 状态栏。
  TraversalFn _chipsTraversal(int count) {
    return (current, direction, _) {
      switch (direction) {
        case DPad.up:
        case DPad.left:
          return current > 0 ? current - 1 : -1;
        case DPad.down:
        case DPad.right:
          return current < count - 1 ? current + 1 : -1;
      }
    };
  }

  Widget _buildScaffold(
    BuildContext ctx, {
    required bool isAggregate,
    required AsyncValue<List<MediaItem>> searchResults,
    required List<String> searchHistory,
    int? resultOffset,
    FocusSectionLayout? aggLayout,
    bool isAggregateResults = false,
  }) {
    final useTv = isTvPlatform &&
        TvFocusManager.instance.getArea('search') != null;
    FocusNode? node(int i) => useTv ? ctx.getFocusNode('search', i) : null;
    // 结果条目节点：单列模式 resultOffset=2（条目从索引 2 起线性排布）；
    // 聚合模式按 FocusSectionLayout 定位（头部 2 元素 + 各行卡片）。
    FocusNode? resultNode(String sectionId, int index) {
      if (!useTv || aggLayout == null) return null;
      return ctx.getFocusNode(
          'search', aggLayout.indexOf(sectionId, index));
    }
    return Scaffold(
      appBar: AppBar(
        title: TvInputField(
          // TV 两段式：聚焦仅高亮，OK 后进入编辑输入。
          focusNode: node(0),
          borderRadius: 6,
          buildEditor: (ctx, editorNode) => TextField(
            controller: _searchController,
            // TV：不自动聚焦（状态栏上键/右键才切入搜索框），手机端保持。
            autofocus: !isTvPlatform,
            focusNode: editorNode,
            decoration: InputDecoration(
              hintText: '搜索...',
              border: InputBorder.none,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        ref.read(searchQueryProvider.notifier).state = '';
                        setState(() => _showResults = false);
                      },
                    ),
                  // 聚合搜索开关（TV：右键从搜索框聚焦此处，OK 切换）。
                  TvFocusable(
                    focusNode: node(1),
                    onActivate: () => ref
                        .read(aggregateSearchProvider.notifier)
                        .state = !isAggregate,
                    borderRadius: 14,
                    child: _AggregateToggle(
                      isAggregate: isAggregate,
                      onToggle: (value) {
                        ref.read(aggregateSearchProvider.notifier).state =
                            value;
                      },
                    ),
                  ),
                ],
              ),
            ),
            onSubmitted: (value) {
              if (value.isNotEmpty) {
                ref.read(searchQueryProvider.notifier).state = value;
                ref.read(searchHistoryProvider.notifier).addQuery(value);
                setState(() => _showResults = true);
              }
            },
            onChanged: (value) {
              setState(() {});
            },
          ),
        ),
      ),
      body: _showResults
          ? _buildSearchResults(
              searchResults,
              resultOffset: resultOffset,
              resultNode: resultNode,
            )
          : _buildSearchHistory(searchHistory),
    );
  }
  
  Widget _buildSearchHistory(List<String> history) {
    if (history.isEmpty) {
      return _buildEmptyState();
    }
    
    final useTv = isTvPlatform &&
        TvFocusManager.instance.getArea('search') != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '搜索历史',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            TextButton(
              onPressed: () => ref.read(searchHistoryProvider.notifier).clear(),
              child: const Text('清除'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < history.length; i++)
              _HistoryChip(
                query: history[i],
                // TV：chips 由 'search' 区域管理（索引 2+i）。
                focusNode: useTv
                    ? context.getFocusNode('search', 2 + i)
                    : null,
                onPressed: () {
                  final query = history[i];
                  _searchController.text = query;
                  ref.read(searchQueryProvider.notifier).state = query;
                  setState(() => _showResults = true);
                },
                onDeleted: () => ref
                    .read(searchHistoryProvider.notifier)
                    .removeQuery(history[i]),
              ),
          ],
        ),
      ],
    );
  }

/// TV 可聚焦历史 chip（手机端 InputChip 原样）。
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.query,
    required this.onPressed,
    required this.onDeleted,
    this.focusNode,
  });

  final String query;
  final VoidCallback onPressed;
  final VoidCallback onDeleted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final chip = InputChip(
      label: Text(query),
      onPressed: onPressed,
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: onDeleted,
    );
    if (!isTvPlatform || focusNode == null) return chip;
    return TvFocusable(
      onActivate: onPressed,
      focusNode: focusNode,
      borderRadius: 16,
      child: chip,
    );
  }
}
  
  Widget _buildSearchResults(
    AsyncValue<List<MediaItem>> results, {
    int? resultOffset,
    FocusNode? Function(String sectionId, int index)? resultNode,
  }) {
    final server = ref.watch(currentServerProvider);
    if (!_showResults) return _buildSearchHistory(ref.watch(searchHistoryProvider));
    // 飞牛是媒体库 API，不兼容 Emby 的 SearchApi。单服搜索直接走飞牛后端，
    // 保留封面鉴权和 GUID，详情页也进入飞牛媒体详情而非旧 Emby 页面。
    if (server != null &&
        server.sourceKind == SourceKind.feiniu &&
        !ref.watch(aggregateSearchProvider)) {
      return _buildFeiniuSearchResults(
        server,
        resultOffset: resultOffset,
        resultNode: resultNode,
      );
    }
    final isAggregate = ref.watch(aggregateSearchProvider);
    if (isAggregate) {
      // 聚合模式独立渲染：Emby 分组 + 飞牛分组并行展示。
      // 不经过 searchResults 的 loading/empty 判断——聚合结果由
      // aggregateSearchResultsProvider / aggregateFeiniuSearchProvider 提供。
      return _buildAggregateResults(resultNode: resultNode);
    }
    return results.when(
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('没有找到结果'));
        }
        
        return ListView.builder(
            // TV：cacheExtent 预构建，确保懒加载结果条目焦点节点挂载。
            cacheExtent: 3000,
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final api = ref.read(apiClientProvider);
              final imageUrls = resolveMediaItemImageUrls(
                api,
                item,
                maxWidth: 120,
                preferThumb: item.type == 'Episode',
              );
              // TV：结果条目包 TvFocusable（遥控遍历 + OK 打开详情），
              // 节点由 'search' 区域统一管理（resultOffset=2 起线性排布）。
              final tile = Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  onTap: () => context.push(mediaRouteForItem(item)),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 60,
                      height: 90,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: imageUrls.isNotEmpty
                          ? MediaImage(
                              imageUrl: imageUrls.first,
                              imageUrls: imageUrls.length > 1
                                  ? imageUrls.sublist(1)
                                  : null,
                              width: 60,
                              height: 90,
                              fit: BoxFit.contain,
                            )
                          : const Icon(Icons.image),
                    ),
                  ),
                title: Text(item.name),
                subtitle: Text(
                  item.type == 'Movie' ? '电影' : '剧集',
                  style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                ),
                trailing: item.communityRating != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, size: 16, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(item.communityRating!.toStringAsFixed(1)),
                        ],
                      )
                    : null,
              ),
              );
              if (isTvPlatform && resultOffset != null) {
                return TvFocusable(
                  onActivate: () => context.push(mediaRouteForItem(item)),
                  focusNode: context.getFocusNode('search', resultOffset + index),
                  borderRadius: 12,
                  child: tile,
                );
              }
              return tile;
            },
        );
      },
      loading: () => const AppLoadingIndicator(),
      error: (error, _) => Center(child: Text('搜索失败: $error')),
    );
  }
  
  Widget _buildFeiniuSearchResults(
    ServerConfig server, {
    int? resultOffset,
    FocusNode? Function(String sectionId, int index)? resultNode,
  }) {
    final query = ref.watch(searchQueryProvider);
    final entries = ref.watch(
      feiniuSearchResultsProvider((serverId: server.id, query: query)),
    );
    return entries.when(
      loading: () => const AppLoadingIndicator(),
      error: (error, _) => Center(child: Text('搜索失败: $error')),
      data: (items) {
        if (items.isEmpty) return const Center(child: Text('没有找到结果'));
        return ListView.separated(
          // TV：cacheExtent 预构建，确保懒加载结果条目焦点节点挂载。
          cacheExtent: 3000,
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final entry = items[index];
            final open = () {
              ref.read(currentServerProvider.notifier).state = server;
              ref.read(authStateProvider.notifier).state =
                  AuthState.authenticated;
              context.push(
                '/detail/${Uri.encodeComponent(entry.id)}',
                extra: UnifiedMediaDetailRouteExtra(
                  server: server,
                  entry: unifiedEntryFromSource(entry),
                ),
              );
            };
            final tile = Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.all(10),
                onTap: open,
                leading: SizedBox(
                  width: 58,
                  height: 86,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: entry.thumbUrl?.isNotEmpty == true
                        ? MediaImage(
                            imageUrl: entry.thumbUrl,
                            httpHeaders: entry.thumbHeaders,
                            fit: BoxFit.cover,
                          )
                        : ColoredBox(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: const Icon(Icons.movie_outlined),
                          ),
                  ),
                ),
                title: Text(entry.name,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  (entry.raw?['type'] ?? '媒体资源').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            );
            if (isTvPlatform && resultOffset != null) {
              return TvFocusable(
                onActivate: open,
                focusNode: context.getFocusNode('search', resultOffset + index),
                borderRadius: 12,
                child: tile,
              );
            }
            return tile;
          },
        );
      },
    );
  }

  Widget _buildAggregateResults({
    FocusNode? Function(String sectionId, int index)? resultNode,
  }) {
    // 复用共享的跨服务器聚合 provider（并行查询 + 失败记日志），不再在 UI 层
    // 自己串行遍历服务器，三端口径统一。每台服务器一行，横向滑动浏览封面。
    final aggregateAsync = ref.watch(aggregateSearchResultsProvider);
    final feiniuAsync = ref.watch(
      aggregateFeiniuSearchProvider(ref.watch(searchQueryProvider)),
    );

    final aggregateData = aggregateAsync.asData?.value ??
        const <String, List<MediaItem>>{};
    final feiniuGroups = feiniuAsync.asData?.value ?? const <FeiniuSearchGroup>[];
    if (aggregateData.isEmpty &&
        feiniuGroups.isEmpty &&
        (aggregateAsync.isLoading || feiniuAsync.isLoading)) {
      return const AppLoadingIndicator();
    }
    if (aggregateData.isEmpty && feiniuGroups.isEmpty) {
      if (aggregateAsync.hasError && feiniuAsync.hasError) {
        return const Center(child: Text('搜索失败，请稍后重试'));
      }
      return const Center(child: Text('没有找到结果'));
    }

    return ListView(
      // TV：cacheExtent 预构建，确保聚合横向行焦点节点挂载。
      cacheExtent: 3000,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        for (final group in aggregateData.entries)
          _EmbyAggregateSection(
            serverName: group.key,
            items: group.value,
            nodeOf: resultNode == null
                ? null
                : (i) => resultNode('agg_${group.key}', i),
          ),
        for (var gi = 0; gi < feiniuGroups.length; gi++)
          _FeiniuAggregateSection(
            group: feiniuGroups[gi],
            nodeOf: resultNode == null
                ? null
                : (i) => resultNode('feiniu_$gi', i),
          ),
      ],
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '输入关键词开始搜索',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _EmbyAggregateSection extends StatelessWidget {
  const _EmbyAggregateSection({
    required this.serverName,
    required this.items,
    this.nodeOf,
  });
  final String serverName;
  final List<MediaItem> items;
  final FocusNode? Function(int index)? nodeOf;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          ServerGroupHeader(
              serverId: items.first.sourceServerId, serverName: serverName),
          const SizedBox(height: 10),
          SizedBox(
            height: 214,
            child: ListView.separated(
              // TV：cacheExtent 覆盖整行，确保视口外卡片节点挂载。
              cacheExtent: 5000,
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, index) => _AggregatePosterCard(
                item: items[index],
                focusNode: nodeOf?.call(index),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
}

class _FeiniuAggregateSection extends ConsumerWidget {
  const _FeiniuAggregateSection({required this.group, this.nodeOf});
  final FeiniuSearchGroup group;
  final FocusNode? Function(int index)? nodeOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          ServerGroupHeader(
              serverId: group.server.id, serverName: group.server.name),
          const SizedBox(height: 10),
          SizedBox(
            height: 214,
            child: ListView.separated(
              // TV：cacheExtent 覆盖整行，确保视口外卡片节点挂载。
              cacheExtent: 5000,
              scrollDirection: Axis.horizontal,
              itemCount: group.entries.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final entry = group.entries[index];
                final open = () {
                  // 与历史页/详情页入口一致：先切当前服务器并标记已认证，
                  // 再经 go_router 统一路由打开（带真实类型 entry），
                  // 避免手动 Navigator.push 与 shell 混用导致灰屏。
                  ref.read(currentServerProvider.notifier).state =
                      group.server;
                  ref.read(authStateProvider.notifier).state =
                      AuthState.authenticated;
                  context.push(
                    '/detail/${Uri.encodeComponent(entry.id)}',
                    extra: UnifiedMediaDetailRouteExtra(
                      server: group.server,
                      entry: unifiedEntryFromSource(entry),
                    ),
                  );
                };
                final card = SizedBox(
                  width: 110,
                  child: GestureDetector(
                    onTap: open,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 110,
                            height: 165,
                            child: MediaImage(
                              imageUrl: entry.thumbUrl,
                              httpHeaders: entry.thumbHeaders,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(entry.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, height: 1.2)),
                      ],
                    ),
                  ),
                );
                final node = nodeOf?.call(index);
                if (isTvPlatform && node != null) {
                  return TvFocusable(
                    onActivate: open,
                    focusNode: node,
                    borderRadius: 12,
                    child: card,
                  );
                }
                return card;
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
}

/// 聚合搜索一行内的封面卡：封面 + 下方标题。点按打开（跨服务器先切服务器）。
class _AggregatePosterCard extends ConsumerWidget {
  final MediaItem item;
  final FocusNode? focusNode;
  const _AggregatePosterCard({required this.item, this.focusNode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const w = 110.0;
    const h = 165.0;
    final api = apiClientForItem(ref, item);
    final imageUrls = resolveMediaItemImageUrls(api, item, maxWidth: 240);
    final card = SizedBox(
      width: w,
      child: GestureDetector(
        onTap: () => openMediaItem(ref, context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: w,
                height: h,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: imageUrls.isNotEmpty
                    ? MediaImage(
                        imageUrl: imageUrls.first,
                        imageUrls:
                            imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                        width: w,
                        height: h,
                        fit: BoxFit.cover,
                      )
                    : const Icon(Icons.image, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, height: 1.2),
            ),
          ],
        ),
      ),
    );
    if (isTvPlatform && focusNode != null) {
      return TvFocusable(
        onActivate: () => openMediaItem(ref, context, item),
        focusNode: focusNode,
        borderRadius: 12,
        child: card,
      );
    }
    return card;
  }
}

/// 聚合搜索开关
class _AggregateToggle extends StatelessWidget {
  final bool isAggregate;
  final ValueChanged<bool> onToggle;
  
  const _AggregateToggle({
    required this.isAggregate,
    required this.onToggle,
  });
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '聚合',
            style: TextStyle(
              fontSize: 12,
              color: isAggregate
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          Switch(
            value: isAggregate,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
