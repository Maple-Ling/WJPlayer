import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/library_filter_utils.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/library_filter_bar.dart';
import '../../widgets/common/media_widgets.dart';

/// 媒体库详情页
class LibraryDetailScreen extends ConsumerStatefulWidget {
  final String libraryId;
  
  const LibraryDetailScreen({super.key, required this.libraryId});
  
  @override
  ConsumerState<LibraryDetailScreen> createState() => _LibraryDetailScreenState();
}

class _LibraryDetailScreenState extends ConsumerState<LibraryDetailScreen> {
  late LibraryFilterValue _filter;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 排序从持久化偏好恢复；其它筛选（类型/标签/年份）保持每次进页面重置。
    final sort = ref.read(librarySortProvider);
    _filter = LibraryFilterValue(
      sortBy: sort.sortBy,
      sortDescending: sort.descending,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onFilterChanged(LibraryFilterValue v) {
    setState(() => _filter = v);
    // 排序变化落盘，退出播放器返回后仍生效。
    ref.read(librarySortProvider.notifier).state =
        LibrarySortPref(sortBy: v.sortBy, descending: v.sortDescending);
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(libraryItemsProvider((
      libraryId: widget.libraryId,
      sortBy: _filter.sortBy,
      sortOrder: _filter.sortDescending ? 'Descending' : 'Ascending',
      genres: _filter.genre,
      tags: _filter.tag,
      studioIds: _filter.studioId,
      studios: _filter.studio,
      years: _filter.yearsCsv,
      ratingMin: _filter.ratingMin,
      ratingMax: _filter.ratingMax,
    )));
    final filtersAsync = ref.watch(filtersProvider(widget.libraryId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库'),
      ),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // 筛选面板：随网格下滑往上渐隐并滚出（与桌面端一致——面板不再固定占顶）。
          filtersAsync.maybeWhen(
            data: (facets) => SliverToBoxAdapter(
              child: AnimatedBuilder(
                animation: _scrollController,
                builder: (context, child) {
                  final offset = _scrollController.hasClients
                      ? _scrollController.offset
                      : 0.0;
                  // ponytail: 前 90px 线性渐隐；面板本身也随滚动上移滑出，二者叠加=往上逐渐消失。
                  final opacity = (1 - offset / 90).clamp(0.0, 1.0);
                  return Opacity(opacity: opacity, child: child);
                },
                child: LibraryFilterBar(
                  facets: facets,
                  value: _filter,
                  currentYear: DateTime.now().year,
                  compact: true, // 移动端：类型/标签走搜索弹窗，避免筛选面板占满屏幕
                  onChanged: _onFilterChanged,
                ),
              ),
            ),
            orElse: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // 内容网格
          itemsAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('暂无内容')),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.55,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = items[index];
                      return MediaPoster(
                        item: item,
                        width: double.infinity,
                        height: double.infinity,
                        onTap: () => context.push(mediaRouteForItem(item)),
                        heroTag: 'library_${item.id}',
                      ).appEntrance(index: index);
                    },
                    childCount: items.length,
                  ),
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: AppLoadingIndicator(),
            ),
            error: (error, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('加载失败: $error')),
            ),
          ),
        ],
      ),
    );
  }
}
