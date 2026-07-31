import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/ranking/ranking_models.dart';
import '../../../core/providers/media_providers.dart';
import '../../utils/media_helpers.dart';
import 'media_widgets.dart';

/// 点按榜单条目后展示的聚合面板内容（三端共用）：
/// 顶部是被点的条目本身，下面按服务器聚合「在哪台服务器有、共多少集」，点某台即打开。
/// 移动端用底部弹窗承载，桌面/TV 用居中弹窗承载。
class RankingEntryPanel extends ConsumerWidget {
  const RankingEntryPanel({super.key, required this.entry});

  final RankingEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(rankingCrossServerMatchProvider(entry.title));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _EntryHeader(entry: entry),
          const SizedBox(height: 16),
          Text(
            '在已登录服务器中查找',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: Text('搜索失败，请稍后重试',
                      style: theme.textTheme.bodyMedium),
                ),
              ),
              data: (matches) {
                if (matches.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 36),
                    child: Center(child: Text('未在任何服务器找到')),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: matches.length,
                  itemBuilder: (_, i) => _ServerMatchRow(match: matches[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryHeader extends StatelessWidget {
  const _EntryHeader({required this.entry});

  final RankingEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accent(entry.rank);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: MediaImage(
            imageUrl: entry.imageUrl,
            width: 58,
            height: 82,
            fit: BoxFit.cover,
            cacheWidth: 174,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (entry.rank > 0)
                    Container(
                      margin: const EdgeInsets.only(top: 2, right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (accent ?? theme.colorScheme.primary)
                            .withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        '#${entry.rank}',
                        style: TextStyle(
                          color: accent ?? theme.colorScheme.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if ((entry.subtitle ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  entry.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (entry.rating != null && entry.rating! > 0) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded,
                        size: 15, color: Color(0xFFFFB300)),
                    const SizedBox(width: 3),
                    Text(
                      entry.rating!.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFFA000),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ServerMatchRow extends ConsumerWidget {
  const _ServerMatchRow({required this.match});

  final ServerMatchInfo match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final api = apiClientForItem(ref, match.item);
    final urls = resolveMediaItemImageUrls(api, match.item, maxWidth: 180);
    final epLabel =
        match.episodeCount != null ? '共 ${match.episodeCount} 集' : '集数 —';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).pop();
        openMediaItem(ref, context, match.item);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MediaImage(
                imageUrl: urls.isNotEmpty ? urls.first : null,
                imageUrls: urls.length > 1 ? urls.sublist(1) : null,
                width: 48,
                height: 68,
                fit: BoxFit.cover,
                cacheWidth: 140,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.serverName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      epLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

Color? _accent(int rank) => switch (rank) {
      1 => const Color(0xFFFFC107),
      2 => const Color(0xFFB0BEC5),
      3 => const Color(0xFFCD7F32),
      _ => null,
    };

/// 用「标题 + 封面」在已登录服务器里查找并打开的通用面板（追剧日历等复用榜单弹窗）。
/// [dialog] 为 true 走居中弹窗（桌面/TV），否则底部弹窗（移动端）。
void showCrossServerLookup(
  BuildContext context, {
  required String title,
  String? imageUrl,
  String? subtitle,
  bool dialog = false,
}) {
  final entry = RankingEntry(
    source: RankingSource.tmdb,
    id: '',
    title: title,
    rank: 0, // 0 = 非榜单来源，隐藏名次徽标
    imageUrl: imageUrl,
    subtitle: subtitle,
  );
  dialog
      ? showRankingEntryDialog(context, entry)
      : showRankingEntrySheet(context, entry);
}

/// 移动端：底部弹窗承载聚合面板。
void showRankingEntrySheet(BuildContext context, RankingEntry entry) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: RankingEntryPanel(entry: entry),
      ),
    ),
  );
}

/// 桌面/TV：居中弹窗承载聚合面板。
void showRankingEntryDialog(BuildContext context, RankingEntry entry) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: RankingEntryPanel(entry: entry),
      ),
    ),
  );
}
