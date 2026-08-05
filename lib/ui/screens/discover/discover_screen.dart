import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/discover/discover_models.dart';
import '../../../core/providers/discover_providers.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/common/media_widgets.dart';
import 'external_media_detail_screen.dart';

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(reviewSourceProvider);
    final sections = ref.watch(discoverSectionsProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: _SourceCapsuleSelector(
          source: source,
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
          data: (values) {
            final visible = values.where((section) => section.entries.isNotEmpty).toList();
            return visible.isEmpty
                ? _DiscoverEmpty(source: source)
                : _DiscoverSections(source: source, sections: visible);
          },
        ),
      ),
    );
  }
}

/// 影视来源胶囊选择器：水平居中，宽度贴合文字，绿色·指示加粗；
/// 点开在当前胶囊原位正下方展开垂直列表（当前项置顶），选完即收起。
class _SourceCapsuleSelector extends StatefulWidget {
  const _SourceCapsuleSelector({required this.source, required this.onChanged});
  final ReviewSource source;
  final ValueChanged<ReviewSource> onChanged;

  @override
  State<_SourceCapsuleSelector> createState() => _SourceCapsuleSelectorState();
}

class _SourceCapsuleSelectorState extends State<_SourceCapsuleSelector> {
  bool _open = false;
  final GlobalKey _anchorKey = GlobalKey();

  @override
  void didUpdateWidget(covariant _SourceCapsuleSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部切换来源（如其他入口）时收起菜单，避免指示与展开态不一致。
    if (oldWidget.source != widget.source && _open) {
      _open = false;
    }
  }

  void _toggle() => setState(() => _open = !_open);

  void _select(ReviewSource value) {
    if (value != widget.source) widget.onChanged(value);
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CapsulePill(
          key: _anchorKey,
          source: widget.source,
          selected: true,
          open: _open,
          onTap: _toggle,
        ),
        // 原位正下方展开，不覆盖顶部；当前项（豆瓣）就在胶囊这一格。
        Offstage(
          offstage: !_open,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in ReviewSource.values)
                if (value != widget.source)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _CapsulePill(
                      source: value,
                      selected: false,
                      open: false,
                      onTap: () => _select(value),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CapsulePill extends StatelessWidget {
  const _CapsulePill({
    super.key,
    required this.source,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final ReviewSource source;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
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
                open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: onSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoverSections extends StatelessWidget {
  const _DiscoverSections({required this.source, required this.sections});
  final ReviewSource source;
  final List<
      ({DiscoverCategory category, List<DiscoverEntry> entries})> sections;

  bool _isPlatform(String label) => const {
    'Netflix','Prime Video','Disney+','Apple TV+','HBO Max','Hulu','Crunchyroll',
    'YouTube','Paramount+','Bilibili','优酷','爱奇艺','腾讯视频'
  }.contains(label);

  @override
  Widget build(BuildContext context) {
    final platforms = source == ReviewSource.tmdb
        ? sections.where((section) => _isPlatform(section.category.label)).toList()
        : const <({DiscoverCategory category, List<DiscoverEntry> entries})>[];
    final content = sections.where((section) => !_isPlatform(section.category.label)).toList();
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
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              itemCount: platforms.length,
              separatorBuilder: (_, __) => const SizedBox(width: 9),
              itemBuilder: (_, index) => ActionChip(
                avatar: const Icon(Icons.live_tv_rounded, size: 18),
                label: Text(platforms[index].category.label),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _PlatformCatalogScreen(section: platforms[index]),
                )),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        for (final section in content)
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(child: Text(section.category.label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiscoverCategoryScreen(category: section.category))),
                      child: const Text('查看更多'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 226,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  scrollDirection: Axis.horizontal,
                  itemCount: section.entries.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 11),
                  itemBuilder: (_, itemIndex) => SizedBox(width: 120, child: _DiscoverCard(entry: section.entries[itemIndex])),
                ),
              ),
            ]),
          ),
      ],
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
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        childAspectRatio: 0.56,
        mainAxisSpacing: 14,
        crossAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => _DiscoverCard(entry: items[index]),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({required this.entry});
  final DiscoverEntry entry;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ExternalMediaDetailScreen(entry: entry),
      )),
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
            onSelected: (key) => setState(() {
              _sortBy = key;
              _descending = _sortBy == 'create_time';
            }),
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
            onPressed: () => setState(() => _descending = !_descending),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(discoverCategoryProvider(widget.category).notifier).reload(),
        child: async.when(
          loading: () => const _DiscoverLoading(),
          error: (_, __) => const _DiscoverEmpty(source: ReviewSource.tmdb, failed: true),
          data: (items) => GridView.builder(
            controller: _controller,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, childAspectRatio: 0.56, mainAxisSpacing: 14, crossAxisSpacing: 10),
            itemCount: items.length,
            itemBuilder: (_, index) => _DiscoverCard(entry: items[index]),
          ),
        ),
      ),
    );
  }
}
