import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../api/danmaku/danmaku_service.dart';
import '../providers/playback_providers.dart';
import '../utils/danmaku_matcher.dart';
import '../utils/danmaku_postprocess.dart';

/// 播放开始时自动匹配并加载弹幕（三端共用）。此前只有打开「搜索弹幕」面板才会
/// 匹配，用户得手动挑一次才显示；现在播放即自动挑可信度最高的一集弹幕直接显示。
///
/// 动漫专库弹弹Play 只在条目判定为动漫时放行（见 [MediaItem.isAnime] +
/// [DanmakuMatcher.resolveIsAnime]）；电视剧/电影只用自定义聚合源。
class DanmakuAutoLoader {
  /// 自动加载可信度阈值：低于此分不自动上屏，避免给非动漫/错配内容硬塞弹幕。
  /// ponytail: 命中率不佳再调；用户仍可手动搜索覆盖。
  static const double _minScore = 0.5;

  /// 官方弹弹Play 源 id（[DanmakuService.initDandanplay] 固定为此）。
  static const String _officialSourceId = 'dandanplay';

  /// 连续集 ID 锚点：`seriesId|seasonId` → 上次成功加载的 (集号, 弹弹Play episodeId)。
  /// 弹弹Play 同一作品的 episodeId 连续（第 N 集 id +1 = 第 N+1 集），追番看下一集时
  /// 直接 id+1 取弹幕，免再调 match（省一次网络往返 + 提高连贯性）。仅官方源、仅“紧邻
  /// 下一集”时启用，并以「取到的弹幕非空」兜底——猜错（跨季/特殊编号）自动退回全量匹配。
  static final Map<String, ({int epNum, int episodeId})> _anchors = {};

  static String? _anchorKey(MediaItem item) {
    final s = item.seriesId;
    if (s == null || s.isEmpty) return null;
    return '$s|${item.seasonId ?? ''}';
  }

  /// [api] 为空时（网盘/聚合直链等无 Emby 上下文）只按条目自身 genres 判定动漫。
  static Future<void> run(
    WidgetRef ref,
    ApiClientFactory? api,
    MediaItem item,
  ) async {
    try {
      if (!ref.read(danmakuEnabledProvider)) return;
      // 已有弹幕（用户手动加载 / 上一次残留）不覆盖。
      if (ref.read(loadedDanmakuProvider).isNotEmpty) return;

      final service = ref.read(danmakuServiceProvider);
      final allowOfficial = await DanmakuMatcher.resolveIsAnime(
        item,
        fetchItem: api == null ? null : (id) => api.media.getItemDetails(id),
      );
      final epNum = item.indexNumber;
      final anchorKey = _anchorKey(item);

      // 快路径：紧邻下一集用连续 episodeId（+1）直接取，命中即用、免 match。
      if (allowOfficial && epNum != null && anchorKey != null) {
        final anchor = _anchors[anchorKey];
        if (anchor != null && epNum == anchor.epNum + 1) {
          final guessId = anchor.episodeId + 1;
          final items = await _loadComments(
              ref, service, guessId.toString(), _officialSourceId);
          if (items != null && items.isNotEmpty) {
            _anchors[anchorKey] = (epNum: epNum, episodeId: guessId);
            _apply(ref, items);
            return;
          }
        }
      }

      final candidates = await DanmakuMatcher.matchAll(
        service,
        item,
        allowOfficial: allowOfficial,
      );
      if (candidates.isEmpty || candidates.first.score < _minScore) return;

      final best = candidates.first;
      final items =
          await _loadComments(ref, service, best.episodeId, best.sourceId);
      if (items == null || items.isEmpty) return;

      // 记锚点：官方源且 episodeId 为纯数字（弹弹Play 连续 id）才可 +1 推下一集。
      final bid = int.tryParse(best.episodeId);
      if (best.sourceId == _officialSourceId &&
          bid != null &&
          epNum != null &&
          anchorKey != null) {
        _anchors[anchorKey] = (epNum: epNum, episodeId: bid);
      }
      _apply(ref, items);
    } catch (_) {
      // 自动加载失败静默，用户仍可手动搜索。
    }
  }

  /// 取评论 + 过滤去重；失败/为空返回 null（快路径据此决定是否退回全量匹配）。
  static Future<List<DanmakuItem>?> _loadComments(
    WidgetRef ref,
    DanmakuService service,
    String episodeId,
    String sourceId,
  ) async {
    try {
      final raw = await service.getComments(episodeId, sourceId: sourceId);
      return applyDanmakuFilterAndDedup(
        raw,
        blockwords: ref.read(danmakuBlockwordsProvider),
        dedup: ref.read(danmakuDedupProvider),
        dedupWindow: ref.read(danmakuDedupWindowProvider),
      );
    } catch (_) {
      return null;
    }
  }

  /// 上屏前二次校验（期间用户可能切集/手动加载/关弹幕）。
  static void _apply(WidgetRef ref, List<DanmakuItem> items) {
    if (!ref.read(danmakuEnabledProvider)) return;
    if (ref.read(loadedDanmakuProvider).isNotEmpty) return;
    ref.read(loadedDanmakuProvider.notifier).state = items;
  }
}
