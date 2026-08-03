import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/media_widgets.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoriteItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          refreshFavorites(ref);
          await ref.read(favoriteItemsProvider.future);
        },
        child: favoritesAsync.when(
          data: (items) {
            if (items.isEmpty) {
              return const _FavoritesEmptyState();
            }

            return GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.52,
                crossAxisSpacing: 14,
                mainAxisSpacing: 18,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _FavoriteTile(item: item).appEntrance(index: index);
              },
            );
          },
          loading: () => const AppLoadingIndicator(),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.55,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.favorite_outline,
                          size: 54,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '收藏加载失败',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          error.toString(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => refreshFavorites(ref),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新加载'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteTile extends ConsumerWidget {
  const _FavoriteTile({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        Positioned.fill(
          child: MediaPoster(
            item: item,
            width: double.infinity,
            height: double.infinity,
            onTap: () => context.push(mediaRouteForItem(item)),
          ),
        ),
        Positioned(
          top: 6,
          left: 6,
          child: Material(
            color: Colors.black.withValues(alpha: 0.46),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _removeFavorite(context, ref, item),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.favorite,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _removeFavorite(
    BuildContext context,
    WidgetRef ref,
    MediaItem item,
  ) async {
    try {
      final api = ref.read(apiClientProvider);
      await api.favorite.removeFavorite(item.id);
      refreshFavorites(ref);
      ref.invalidate(mediaItemProvider(item.id));

      if (context.mounted) {
        AppToast.show(context, '已从收藏移除 ${item.name}');
      }
    } catch (error) {
      if (context.mounted) {
        AppToast.show(context, '移除收藏失败: $error', kind: AppToastKind.error);
      }
    }
  }
}

class _FavoritesEmptyState extends StatelessWidget {
  const _FavoritesEmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.favorite_border_rounded,
                    size: 68,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '还没有收藏内容',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '在首页或详情页点击收藏后，这里会立即同步显示。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
