/// 集/电影「其他服务器版本」聚合。
///
/// 详情页展示同一集（或同一部电影）在**其它已登录 Emby 服务器**上的所有版本
/// （MediaSource），复用既有跨服基建：
/// - 服务器扇出：[serverListProvider] + [serverApiClientProvider]（每服缓存只读
///   client，单服失败隔离，与聚合搜索同一套路）；可在设置里按服开关（见
///   [aggregationDisabledServersProvider]）。
/// - 内容身份匹配（精确优先）：先用 Provider Id（tmdb/imdb/tvdb）经服务端
///   `AnyProviderIdEquals` 精确反查——剧集查剧的 TMDB 再按季集号定位、电影查自身外部
///   id；无外部 id 或服务器不支持时回退归一化剧名/标题 + 季集号搜索。
/// - 版本正则偏好：[preferredVersionRegexProvider] + [mediaSourceSearchText]，命中
///   的版本优先排在前面并高亮。
///
/// 点击某版本 = 切到来源服务器 + 选中该 MediaSource + 跳完整播放页（复用各端播放
/// 器，与聚合搜索点击跳转同一模式，见 [openMediaItem]）。
library;

import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_interfaces.dart';
import '../providers/reveal_hidden_provider.dart';
import '../services/app_logger.dart';
import '../services/preload_service.dart';
import '../services/watch_history/watch_history_matcher.dart'
    show extractProviderId, normalizeWatchHistoryText;
import '../utils/track_preference.dart';
import 'app_preferences.dart';
import 'media_providers.dart';
import 'playback_providers.dart';
import 'server_providers.dart';

/// 聚合是**次要**任务，绝不能抢起播带宽。进详情页后延后一段再发网络请求：用户「开页
/// 即点播」的常见流里，聚合根本还没开跑，MPV 起播独享带宽；只有停在详情页浏览时才加载。
const Duration _kAggregationStartDelay = Duration(milliseconds: 1800);

/// 起跑后若预热(PreloadService)仍在拉 32MB 头部，再等它空闲（最多这么久）才发聚合请求，
/// 让出关键起播带宽。超时则不再干等（避免预热异常时聚合永不出现）。
const Duration _kMaxWarmWait = Duration(seconds: 6);

/// 被用户关闭「参与聚合」的服务器 id 集合（默认空 = 全部参与）。
/// 存已关闭的一方：新加入的服务器不在集合里，即默认参与，符合「开=允许」。
final aggregationDisabledServersProvider =
    StateNotifierProvider<AggregationDisabledServersNotifier, Set<String>>(
        (ref) => AggregationDisabledServersNotifier());

class AggregationDisabledServersNotifier extends StateNotifier<Set<String>> {
  AggregationDisabledServersNotifier() : super(_load());

  static const _prefKey = 'wjplayer_aggregation_disabled_servers';

  static Set<String> _load() {
    try {
      return AppPreferencesStore.instance.getStringList(_prefKey)?.toSet() ??
          <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  void _persist() {
    try {
      AppPreferencesStore.instance.setStringList(_prefKey, state.toList());
    } catch (_) {
      // 持久化失败不影响内存状态。
    }
  }

  bool isEnabled(String serverId) => !state.contains(serverId);

  /// 设置某服务器是否参与聚合（enabled=true 参与）。
  void setEnabled(String serverId, bool enabled) {
    final next = Set<String>.from(state);
    if (enabled) {
      next.remove(serverId);
    } else {
      next.add(serverId);
    }
    state = next;
    _persist();
  }
}

/// 聚合栏里的一条：某台服务器上匹配到的同集/同影的一个版本。
class AggregatedVersion {
  final ServerConfig server;

  /// 该服务器上匹配到的条目（已打 [MediaItem.sourceServerId]），供点击跳转。
  final MediaItem item;

  /// 该条目的一个版本（MediaSource）。
  final MediaSource source;

  /// 是否命中用户的「版本偏好正则」（[preferredVersionRegexProvider]）。命中者优先。
  final bool matchesRegex;

  const AggregatedVersion({
    required this.server,
    required this.item,
    required this.source,
    required this.matchesRegex,
  });
}

/// 聚合当前条目在**其它** Emby 服务器上的所有版本，正则命中优先、按服务器顺序、
/// 清晰度降序排列。仅 Episode/Movie 有意义；无其它可用服务器或匹配不到时返回空。
///
/// **逐台增量**：用 [StreamProvider] + [Stream.fromFutures]，哪台服务器先匹配到就先
/// emit 一版累积结果，一台慢/掉线不阻塞其它台（不再 `Future.wait` 等齐才出）。
final episodeAggregationProvider = StreamProvider.autoDispose
    .family<List<AggregatedVersion>, String>((ref, itemId) async* {
  final item = await ref.watch(mediaItemProvider(itemId).future);
  final kind = item.type.toLowerCase();
  final isEpisode = kind == 'episode';
  if (!isEpisode && kind != 'movie') {
    yield const <AggregatedVersion>[];
    return;
  }

  final homeServerId =
      item.sourceServerId ?? ref.read(currentServerProvider)?.id;

  // 只聚合其它「已登录的 Emby 服务器」——文件浏览型源（网盘/Ani-rss）无 Emby 版本概念；
  // 且排除用户在设置里关闭了「参与聚合」的服务器。
  final disabled = ref.watch(aggregationDisabledServersProvider);
  // 服务器列表三击显示隐藏服务器后，隐藏标记的服务器同样参与聚合展示
  // （与列表可见性一致）。
  final revealHidden = ref.watch(revealHiddenServersProvider);
  final servers = ref.watch(serverListProvider).where((s) {
    // 隐藏属性的服务器默认严禁参与任何聚合展示：与聚合搜索
    // 公共链路（aggregateSearchByQueryProvider）同规则，杜绝隐私服务器暴露。
    return !s.isFileBrowse &&
        (s.authToken ?? '').isNotEmpty &&
        (s.hidden != true || revealHidden) &&
        s.id != homeServerId &&
        !disabled.contains(s.id);
  }).toList();
  if (servers.isEmpty) {
    yield const <AggregatedVersion>[];
    return;
  }

  // 让路给起播：先延后，再等预热空闲，之后才发聚合网络请求。离开详情页则中止 +
  // **直接杀掉在飞的 HTTP 请求**（cancelToken.cancel），别让它继续占服务器/连接。
  var disposed = false;
  final cancelToken = CancelToken();
  ref.onDispose(() {
    disposed = true;
    if (!cancelToken.isCancelled) cancelToken.cancel('aggregation-disposed');
  });
  await Future<void>.delayed(_kAggregationStartDelay);
  if (disposed) return;
  var waited = Duration.zero;
  while (PreloadService.instance.isWarming && waited < _kMaxWarmWait) {
    const step = Duration(milliseconds: 250);
    await Future<void>.delayed(step);
    waited += step;
    if (disposed) return;
  }

  final regex = compilePreferenceRegex(ref.read(preferredVersionRegexProvider));

  // 目标身份。
  final normSeries = normalizeWatchHistoryText(item.seriesName ?? '');
  final normTitle = normalizeWatchHistoryText(item.name);
  final season = item.parentIndexNumber;
  final episode = item.indexNumber;
  final year = item.productionYear;
  // 条目自身的可用外部 id（电影精确反查用；剧集主要靠剧 TMDB + 季集号）。
  final targetProviderIds = <String, String>{};
  for (final key in const ['tmdb', 'imdb', 'tvdb']) {
    final v = extractProviderId(item.providerIds, key);
    if (v != null && v.isNotEmpty) targetProviderIds[key] = v;
  }

  // 剧集的「剧 TMDB」需从剧条目取（集自身常无剧 TMDB）。用来源服务器 client 解析。
  String? targetSeriesTmdb;
  if (isEpisode && item.seriesId != null && item.seriesId!.isNotEmpty) {
    final homeClient = homeServerId != null
        ? ref.read(serverApiClientProvider(homeServerId))
        : null;
    final ApiClientFactory client = homeClient ?? ref.read(apiClientProvider);
    try {
      final series = await client.media
          .getItemDetails(item.seriesId!, cancelToken: cancelToken);
      targetSeriesTmdb = extractProviderId(series.providerIds, 'tmdb');
    } catch (_) {
      // 取不到剧 TMDB 不致命，回退按剧名 + 季集号匹配。
    }
  }

  final query = isEpisode ? (item.seriesName ?? item.name) : item.name;

  Future<List<AggregatedVersion>> versionsOf(ServerConfig server) async {
    final client = ref.read(serverApiClientProvider(server.id));
    if (client == null) return const <AggregatedVersion>[];
    try {
      final matched = await _locateItem(
        client: client,
        query: query,
        isEpisode: isEpisode,
        normSeries: normSeries,
        normTitle: normTitle,
        season: season,
        episode: episode,
        year: year,
        targetSeriesTmdb: targetSeriesTmdb,
        targetProviderIds: targetProviderIds,
        cancelToken: cancelToken,
      );
      if (matched == null) return const <AggregatedVersion>[];
      // 打来源标记：让封面/点击解析到正确的服务器（见 MediaItem.sourceServerId）。
      matched.sourceServerId = server.id;
      // 轻量枚举版本（不开流/不 ffprobe），避免在其它服务器上开启播放会话拖慢本机起播。
      final sources = await client.media
          .getItemMediaSources(matched.id, cancelToken: cancelToken);
      return sources
          .map((s) => AggregatedVersion(
                server: server,
                item: matched,
                source: s,
                matchesRegex:
                    regex != null && regex.hasMatch(mediaSourceSearchText(s)),
              ))
          .toList();
    } catch (e) {
      AppLogger().w('EpisodeAggregation', '服务器「${server.name}」聚合失败: $e');
      return const <AggregatedVersion>[];
    }
  }

  final order = <String, int>{
    for (var i = 0; i < servers.length; i++) servers[i].id: i,
  };

  // 全部服务器并发发起、按完成顺序逐台出：哪台先匹配到就先 emit，一台慢/掉线不拖累
  // 其它台。仅查条目元数据（文本，非图片/音视频），并发本就吃不了多少带宽，不再限流；
  // 真正省资源的是离开页面即 cancelToken 杀请求（见 onDispose）。
  final all = <AggregatedVersion>[];
  var emitted = false;
  await for (final list in Stream.fromFutures(servers.map(versionsOf))) {
    if (disposed) return;
    if (list.isEmpty) continue;
    all.addAll(list);
    sortAggregatedVersions(all, order);
    emitted = true;
    yield List<AggregatedVersion>.of(all);
  }
  // 全部服务器都无匹配：emit 一次空，让 UI 从 loading 落到「无版本」而非一直转圈。
  if (!emitted && !disposed) yield const <AggregatedVersion>[];
});

/// 排序：① 正则命中优先 ② 服务器原顺序 ③ 同服内清晰度（像素）降序。
/// 抽成纯函数以便测试（守住「优先显示匹配到正则的版本」这条核心承诺）。
void sortAggregatedVersions(
  List<AggregatedVersion> versions,
  Map<String, int> serverOrder,
) {
  int px(MediaSource s) {
    final v = s.primaryVideoStream;
    return (v?.width ?? 0) * (v?.height ?? 0);
  }

  versions.sort((a, b) {
    if (a.matchesRegex != b.matchesRegex) return a.matchesRegex ? -1 : 1;
    final so =
        (serverOrder[a.server.id] ?? 0).compareTo(serverOrder[b.server.id] ?? 0);
    if (so != 0) return so;
    return px(b.source).compareTo(px(a.source));
  });
}

/// 在一台服务器上定位与目标身份对应的条目（返回完整 [MediaItem]，含 id 供取版本）。
///
/// 精确优先：先用 Provider Id（tmdb/imdb/tvdb）经 `AnyProviderIdEquals` 精确反查
/// （剧集查剧的 TMDB、电影查自身外部 id），命中最准；服务器不支持该参数或无外部 id
/// 时，回退归一化标题 + 季集号搜索匹配。
Future<MediaItem?> _locateItem({
  required ApiClientFactory client,
  required String query,
  required bool isEpisode,
  required String normSeries,
  required String normTitle,
  required int? season,
  required int? episode,
  required int? year,
  required String? targetSeriesTmdb,
  required Map<String, String> targetProviderIds,
  CancelToken? cancelToken,
}) async {
  if (isEpisode) {
    if (episode == null) return null;

    // 1) 精确：按剧的 TMDB 反查剧。
    MediaItem? series;
    if (targetSeriesTmdb != null && targetSeriesTmdb.isNotEmpty) {
      final found = await client.media.findItemsByProviderIds(
        {'tmdb': targetSeriesTmdb},
        includeItemTypes: 'Series',
        cancelToken: cancelToken,
      );
      if (found.isNotEmpty) series = found.first;
    }

    // 2) 回退：按剧名搜索挑最匹配的剧。
    List<MediaItem> hits = const [];
    if (series == null) {
      hits = await client.search.search(query, cancelToken: cancelToken);
      for (final h in hits) {
        if (h.type != 'Series') continue;
        final ht = normalizeWatchHistoryText(h.name);
        final tmdbOk = targetSeriesTmdb != null &&
            extractProviderId(h.providerIds, 'tmdb') == targetSeriesTmdb;
        if (tmdbOk) {
          series = h;
          break;
        }
        final titleOk = ht.isNotEmpty &&
            normSeries.isNotEmpty &&
            (ht == normSeries ||
                ht.contains(normSeries) ||
                normSeries.contains(ht));
        if (titleOk) series ??= h;
      }
    }

    // 3) 剧下按季→集定位。
    if (series != null) {
      String? seasonId;
      if (season != null) {
        final seasons =
            await client.media.getSeasons(series.id, cancelToken: cancelToken);
        for (final s in seasons) {
          if (s.indexNumber == season) {
            seasonId = s.id;
            break;
          }
        }
        // 只有一季时不强求季号匹配。
        if (seasonId == null && seasons.length == 1) seasonId = seasons.first.id;
      }
      final eps = await client.media
          .getEpisodes(series.id, seasonId: seasonId, cancelToken: cancelToken);
      for (final e in eps) {
        if (e.indexNumber == episode) {
          return client.media.getItemDetails(e.id, cancelToken: cancelToken);
        }
      }
      return null;
    }

    // 4) 搜索结果里直接命中的分集（剧名 + 季集号）作兜底。
    for (final h in hits) {
      if (h.type != 'Episode') continue;
      final hs = normalizeWatchHistoryText(h.seriesName ?? '');
      final seriesOk = hs.isNotEmpty &&
          normSeries.isNotEmpty &&
          (hs == normSeries || hs.contains(normSeries) || normSeries.contains(hs));
      final seasonOk = season == null || h.parentIndexNumber == season;
      if (seriesOk && seasonOk && h.indexNumber == episode) return h;
    }
    return null;
  }

  // 电影：先按外部 id 精确反查，回退归一化标题（年份宽松）取第一条。
  if (targetProviderIds.isNotEmpty) {
    final found = await client.media.findItemsByProviderIds(targetProviderIds,
        includeItemTypes: 'Movie', cancelToken: cancelToken);
    if (found.isNotEmpty) return found.first;
  }
  final hits = await client.search.search(query, cancelToken: cancelToken);
  MediaItem? best;
  for (final h in hits) {
    if (h.type != 'Movie') continue;
    final ht = normalizeWatchHistoryText(h.name);
    final titleOk = ht.isNotEmpty && ht == normTitle;
    final yearOk =
        year == null || h.productionYear == null || h.productionYear == year;
    if (titleOk && yearOk) best ??= h;
  }
  return best;
}

/// 点击聚合版本：切到来源服务器 + 选中该版本 + 复位音轨/字幕 + 跳完整播放页。
///
/// 与聚合搜索点击跳转同一模式（先切 [currentServerProvider] 再导航），否则播放页会
/// 用当前服务器去取一个不存在的 itemId。移动/桌面走 `/player/:id?mediaSourceId=`，
/// TV 走 `/tv/player?mediaId=`（TV 播放页按 [selectedMediaSourceProvider] 选版本）。
void playAggregatedVersion(
  WidgetRef ref,
  BuildContext context,
  AggregatedVersion v, {
  bool isTv = false,
}) {
  if (v.server.id != ref.read(currentServerProvider)?.id) {
    ref.read(currentServerProvider.notifier).syncWithAvailableServers(
          ref.read(serverListProvider),
          preferredServerId: v.server.id,
        );
  }
  ref.read(selectedMediaSourceProvider.notifier).state = v.source.id;
  ref.read(audioTrackProvider.notifier).state = null;
  ref.read(subtitleTrackProvider.notifier).state = null;
  ref.read(secondarySubtitleTrackProvider.notifier).state = null;
  ref.read(currentPlayingItemProvider.notifier).state = v.item;

  final id = v.item.id;
  if (isTv) {
    context.push('/tv/player?mediaId=$id');
  } else {
    context.push(
        '/player/$id?mediaSourceId=${Uri.encodeQueryComponent(v.source.id)}');
  }
}

/// 版本的简短展示标签：清晰度 + 容器（如 "1080p · MKV"），皆缺则回退版本名/「版本」。
String aggregatedVersionLabel(MediaSource source) {
  final parts = <String>[];
  final q = source.qualityLabel;
  if (q.isNotEmpty) parts.add(q);
  final c = source.container;
  if (c != null && c.isNotEmpty) parts.add(c.toUpperCase());
  if (parts.isNotEmpty) return parts.join(' · ');
  final name = source.name;
  if (name != null && name.isNotEmpty) return name;
  return '版本';
}
