import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/discover/discover_models.dart';
import '../../../core/providers/discover_providers.dart';
import '../../../core/services/tv_focus_manager.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/tv_focus_widgets.dart';
import '../../widgets/common/tv_focusable.dart';
import 'external_media_detail_screen.dart';

/// 判断分区是否为「播出平台」行（TMDB 来源时显示）。
bool isPlatformSection(
    ({DiscoverCategory category, List<DiscoverEntry> entries}) section) {
  const platforms = {
    'Netflix', 'Prime Video', 'Disney+', 'Apple TV+', 'HBO Max', 'Hulu',
    'Crunchyroll', 'YouTube', 'Paramount+', 'Bilibili', '优酷', '爱奇艺',
    '腾讯视频'
  };
  return platforms.contains(section.category.label);
}

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(reviewSourceProvider);
    final sections = ref.watch(discoverSectionsProvider);
    // TV：数据就绪时计算焦点布局（来源选择器 index 0 + 平台行 + 内容分区），
    // 包住整个 Scaffold——否则 AppBar 的来源选择器在方向键被区域接管后不可达。
    final visible = sections.maybeWhen(
      data: (values) =>
          values.where((section) => section.entries.isNotEmpty).toList(),
      orElse: () =>
          const <({DiscoverCategory category, List<DiscoverEntry> entries})>[],
    );
    final platforms = source == ReviewSource.tmdb
        ? visible.where(isPlatformSection).toList()
        : const <({DiscoverCategory category, List<DiscoverEntry> entries})>[];
    final content = visible.where((s) => !isPlatformSection(s)).toList();

    Widget buildScaffold(BuildContext ctx, FocusSectionLayout? layout) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          centerTitle: true,
          title: _SourceCapsuleSelector(
            source: source,
            // TV：来源选择器 = 区域 index 0（OK 弹出来源菜单）。
            focusNode:
                layout == null ? null : ctx.getFocusNode('discover', 0),
            onChanged: (value) {
              ref.read(reviewSourceProvider.notifier).state = value;
              ref.invalidate(discoverSectionsProvider);
            },
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(discoverSectionsProvider);
            await ref.read(discoverSectionsProvider.future);
          },
          child: sections.when(
            loading: () => const _DiscoverLoading(),
            error: (_, __) => _DiscoverEmpty(source: source, failed: true),
            data: (values) => visible.isEmpty
                ? _DiscoverEmpty(source: source)
                : _DiscoverSections(
                    source: source,
                    sections: visible,
                    layout: layout,
                  ),
          ),
        ),
      );
    }

    if (!isTvPlatform || visible.isEmpty) {
      return buildScaffold(context, null);
    }
    final tvSections = <FocusSection>[
      const FocusSection('source', 1),
      if (platforms.isNotEmpty) FocusSection('platforms', platforms.length),
      for (var i = 0; i < content.length; i++)
        FocusSection('sec_$i', content[i].entries.length, trailing: true),
    ];
    final layout = FocusSectionLayout(tvSections);
    return TvFocusArea(
      id: 'discover',
      count: layout.totalCount,
      traversal: layout.traversal,
      // Builder：取焦点节点时区域已注册（TvFocusArea 先挂载）。
      child: Builder(builder: (ctx) => buildScaffold(ctx, layout)),
    );
  }
}

/// 影视来源胶囊选择器：水平居中，宽度贴合文字，绿色·指示加粗。
/// 点开后从胶囊正下方弹出三项列表（豆瓣在上，TMDB 居中，IMDb 在下），
/// 当前来源带勾选态，选完即收起。改用 PopupMenuButton 确保三项都可点。
class _SourceCapsuleSelector extends StatelessWidget {
  const _SourceCapsuleSelector({
    required this.source,
    required this.onChanged,
    this.focusNode,
  });
  final ReviewSource source;
  final ValueChanged<ReviewSource> onChanged;

  /// TV 集中焦点管理注入的节点（null = 自建节点，走 Flutter 默认遍历）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<ReviewSource>(
      tooltip: '切换评分来源',
      focusNode: focusNode,
      offset: const Offset(0, -56),
      position: PopupMenuPosition.under,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 6,
      onSelected: (value) {
        if (value != source) onChanged(value);
      },
      itemBuilder: (_) => [
        for (final value in ReviewSource.values)
          PopupMenuItem<ReviewSource>(
            value: value,
            height: 46,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: value == source
                      ? const Icon(Icons.check_rounded,
                          size: 20, color: Color(0xFF34C759))
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  value.label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight:
                        value == source ? FontWeight.w800 : FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: _CapsulePill(source: source, selected: true),
    );
  }
}

class _CapsulePill extends StatelessWidget {
  const _CapsulePill({required this.source, required this.selected});

  final ReviewSource source;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      // 左右只比文字多出一点，整体居中
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 绿色·指示，加粗
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: const Color(0xFF34C759),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            source.label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: onSurface,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: onSurface,
          ),
        ],
      ),
    );
  }
}

class _DiscoverSections extends StatelessWidget {
  const _DiscoverSections({
    required this.source,
    required this.sections,
    this.layout,
  });
  final ReviewSource source;
  final List<
      ({DiscoverCategory category, List<DiscoverEntry> entries})> sections;

  /// TV 焦点布局（null = 手机端或数据未就绪，不接集中焦点管理）。
  /// 区域本身由 DiscoverScreen 包住整个 Scaffold（含 AppBar 来源选择器）。
  final FocusSectionLayout? layout;

  @override
  Widget build(BuildContext context) {
    final platforms = source == ReviewSource.tmdb
        ? sections.where(isPlatformSection).toList()
        : const <({DiscoverCategory category, List<DiscoverEntry> entries})>[];
    final content = sections.where((s) => !isPlatformSection(s)).toList();
    return _buildList(context, platforms, content, layout);
  }

  Widget _buildList(
    BuildContext context,
    List<({DiscoverCategory category, List<DiscoverEntry> entries})> platforms,
    List<({DiscoverCategory category, List<DiscoverEntry> entries})> content,
    FocusSectionLayout? layout,
  ) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: 8, bottom: 88 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (platforms.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Text('播出平台', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          SizedBox(
            height: 52,
            child: ListView.separated(
              // TV：cacheExtent 覆盖整行，确保视口外卡片节点全部挂载
              // （否则确定性遍历聚焦到未挂载节点会静默失败、回退默认遍历乱跳）。
              cacheExtent: 5000,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              itemCount: platforms.length,
              separatorBuilder: (_, __) => const SizedBox(width: 9),
              itemBuilder: (_, index) {
                final platform = platforms[index];
                return TvFocusable(
                  onActivate: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => _PlatformCatalogScreen(section: platform),
                  )),
                  focusNode: layout == null
                      ? null
                      : context.getFocusNode('discover', layout.indexOf('platforms', index)),
                  borderRadius: 16,
                  child: ActionChip(
                    avatar: const Icon(Icons.live_tv_rounded, size: 18),
                    label: Text(platform.category.label),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => _PlatformCatalogScreen(section: platform),
                    )),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
        ],
        for (var i = 0; i < content.length; i++)
          _buildContentSection(context, i, content[i], layout),
      ],
    );
  }

  /// 单个内容分区：标题 + 「查看更多」（行尾焦点节点）+ 横向卡片行。
  Widget _buildContentSection(
    BuildContext context,
    int sectionIndex,
    ({DiscoverCategory category, List<DiscoverEntry> entries}) section,
    FocusSectionLayout? layout,
  ) {
    final sectionId = 'sec_$sectionIndex';
    final hasFocus = layout != null && section.entries.isNotEmpty;
    final moreNode = hasFocus
        ? context.getFocusNode('discover', layout.indexOf(sectionId, section.entries.length))
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(child: Text(section.category.label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
              TextButton(
                // TV：行内上键第一次聚焦到本行「查看更多」；节点由 TvFocusManager 管理。
                focusNode: moreNode,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiscoverCategoryScreen(category: section.category))),
                style: ButtonStyle(
                  overlayColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.focused)
                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.22)
                          : null),
                ),
                child: const Text('查看更多'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 226,
          child: ListView.separated(
            // TV：cacheExtent 覆盖整行（同平台行，防焦点节点未挂载）。
            cacheExtent: 5000,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: section.entries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 11),
            itemBuilder: (_, itemIndex) => SizedBox(
              width: 120,
              child: _DiscoverCard(
                entry: section.entries[itemIndex],
                focusNode: hasFocus
                    ? context.getFocusNode('discover', layout.indexOf(sectionId, itemIndex))
                    : null,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DiscoverGrid extends StatelessWidget {
  const _DiscoverGrid({required this.items});
  final List<DiscoverEntry> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      clipBehavior: Clip.none,
      padding: EdgeInsets.fromLTRB(
        14,
        12,
        14,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        childAspectRatio: 0.56,
        mainAxisSpacing: 18,
        crossAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => _DiscoverCard(entry: items[index]),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({required this.entry, this.focusNode});
  final DiscoverEntry entry;

  /// TV 集中焦点管理注入的节点（null = 自建节点，走 Flutter 默认遍历）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onActivate: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ExternalMediaDetailScreen(entry: entry),
      )),
      focusNode: focusNode,
      borderRadius: 12,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ExternalMediaDetailScreen(entry: entry),
        )),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: entry.posterUrl,
                      httpHeaders: entry.source == ReviewSource.douban
                          ? const {'Referer': 'https://m.douban.com/'}
                          : null,
                      fit: BoxFit.cover,
                    ),
                    if (entry.rating != null && entry.rating! > 0)
                      Positioned(
                        top: 7,
                        left: 7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.76),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded,
                                  size: 13, color: Color(0xFFFFC107)),
                              const SizedBox(width: 2),
                              Text(entry.rating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if ((entry.year ?? '').isNotEmpty)
              Text(entry.year!,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
        ),
      ),
    );
  }
}

class _PlatformCatalogScreen extends StatelessWidget {
  const _PlatformCatalogScreen({required this.section});
  final ({DiscoverCategory category, List<DiscoverEntry> entries}) section;

  @override
  Widget build(BuildContext context) => DiscoverCategoryScreen(
        category: section.category,
      );
}

class _DiscoverLoading extends StatelessWidget {
  const _DiscoverLoading();
  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        childAspectRatio: 0.56,
        mainAxisSpacing: 14,
        crossAxisSpacing: 10,
      ),
      itemCount: 12,
      itemBuilder: (_, __) => const Column(
        children: [
          Expanded(child: ShimmerBox(width: double.infinity, height: 190)),
          SizedBox(height: 8),
          ShimmerBox(width: double.infinity, height: 14),
        ],
      ),
    );
  }
}

class _DiscoverEmpty extends StatelessWidget {
  const _DiscoverEmpty({required this.source, this.failed = false});
  final ReviewSource source;
  final bool failed;
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.28),
        const Icon(Icons.movie_filter_outlined, size: 58),
        const SizedBox(height: 14),
        Center(
          child: Text(failed
              ? '${source.label}数据加载失败，下拉重试'
              : '${source.label}暂时没有可展示内容'),
        ),
      ],
    );
  }
}


class DiscoverCategoryScreen extends ConsumerStatefulWidget {
  const DiscoverCategoryScreen({super.key, required this.category});
  final DiscoverCategory category;
  @override
  ConsumerState<DiscoverCategoryScreen> createState() => _DiscoverCategoryScreenState();
}

class _DiscoverCategoryScreenState extends ConsumerState<DiscoverCategoryScreen> {
  final _controller = ScrollController();
  String _sortBy = 'create_time';
  bool _descending = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.position.pixels > _controller.position.maxScrollExtent - 400) {
        ref.read(discoverCategoryProvider(widget.category).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  void _sort(String key) {
    setState(() {
      if (_sortBy == key) {
        _descending = !_descending;
      } else {
        _sortBy = key;
        _descending = key != 'title';
      }
    });
    ref.read(discoverCategoryProvider(widget.category).notifier)
        .sort(DiscoverSortPref(sortBy: _sortBy, descending: _descending));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(discoverCategoryProvider(widget.category));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.category.label),
        // 排序：与正序/倒序无关的独立排序切换（评分/标题/首映时间/入库时间）
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            tooltip: '排序',
            onSelected: _sort,
            itemBuilder: (_) => [
              for (final option in kDiscoverSortOptions)
                PopupMenuItem(
                  value: option.key,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(option.label),
                      if (option.key == _sortBy)
                        const Icon(Icons.check_rounded,
                            size: 18, color: Color(0xFF34C759)),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert_rounded),
            tooltip: '正序/倒序',
            onPressed: () {
              setState(() => _descending = !_descending);
              ref.read(discoverCategoryProvider(widget.category).notifier).sort(
                    DiscoverSortPref(
                        sortBy: _sortBy, descending: _descending),
                  );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(discoverCategoryProvider(widget.category).notifier).reload(),
        child: async.when(
          loading: () => const _DiscoverLoading(),
          error: (_, __) => const _DiscoverEmpty(source: ReviewSource.tmdb, failed: true),
          data: (items) {
            if (!isTvPlatform || items.isEmpty) {
              return GridView.builder(
                controller: _controller,
                physics: const AlwaysScrollableScrollPhysics(),
                clipBehavior: Clip.none,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, childAspectRatio: 0.56, mainAxisSpacing: 18, crossAxisSpacing: 12),
                itemCount: items.length,
                itemBuilder: (_, index) => _DiscoverCard(entry: items[index]),
              );
            }
            // TV：网格确定性遍历（6 列，上下/左右逐卡移动，禁止随机跳转）。
            const columns = 6;
            return TvFocusArea(
              id: 'discover_category_${widget.category.id}',
              count: items.length,
              traversal: TraversalPolicies.grid(
                columns: columns,
                rowCount: (items.length / columns).ceil(),
              ),
              child: GridView.builder(
                controller: _controller,
                physics: const AlwaysScrollableScrollPhysics(),
                clipBehavior: Clip.none,
                // TV：cacheExtent 预构建，确保网格焦点节点挂载。
                cacheExtent: 3000,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: 0.56,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 12,
                ),
                itemCount: items.length,
                itemBuilder: (_, index) => _DiscoverCard(
                  entry: items[index],
                  focusNode: context.getFocusNode(
                      'discover_category_${widget.category.id}', index),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
