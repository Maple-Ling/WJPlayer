import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_interfaces.dart';
import '../providers/app_providers.dart';
import '../services/app_logger.dart';

/// 有界 LRU 保活：让导航级 provider 的结果在内存里保留「最近若干份」。
///
/// 取舍：纯 autoDispose 离开页面即释放（省内存）但返回会重新联网（网络慢则卡）；
/// 纯 keepAlive 返回秒开但浏览越多驻留越多（移动/TV OOM）。这里折中——
/// 每份结果持有一个 KeepAliveLink 钉在内存，超过 [maxEntries] 就放开最旧的那份，
/// 使其在无人 watch 时被 autoDispose 回收。于是：
/// - 返回最近看过的剧/集 → provider 仍在内存，秒开、**不重新联网**；
/// - 内存恒定有界（元数据每份仅几 KB，60 份 ≈ 1-2MB），不再随浏览无限增长；
/// - 标记已看/收藏后用 ref.invalidate 触发重建 → 重新拉取，**不会显示过期状态**
///   （磁盘缓存做不到这点，故元数据不落盘只做有界内存保活）。
class _BoundedKeepAlive {
  _BoundedKeepAlive({required this.maxEntries});

  final int maxEntries;
  // LinkedHashMap 语义：保持插入顺序，最旧的在 keys.first。
  final Map<String, KeepAliveLink> _links = <String, KeepAliveLink>{};

  /// 在 autoDispose provider 体内调用：保活当前结果并登记到 LRU。
  void retain(String key, Ref ref) {
    final link = ref.keepAlive();
    _links.remove(key)?.close(); // 同 key 旧链接先放开（如 invalidate 重建）
    _links[key] = link;
    ref.onDispose(() {
      if (identical(_links[key], link)) _links.remove(key);
    });
    while (_links.length > maxEntries) {
      final oldestKey = _links.keys.first;
      _links.remove(oldestKey)?.close();
    }
  }
}

/// 详情/集/季/演员/相似/播放信息共用一个 LRU（约 12 部剧的往返足够秒开）。
final _metadataKeepAlive = _BoundedKeepAlive(maxEntries: 60);

class EmbyMediaCounts {
  final int movieCount;
  final int episodeCount;
  final int? itemCount;

  const EmbyMediaCounts({
    required this.movieCount,
    required this.episodeCount,
    this.itemCount,
  });

  int get totalCount => movieCount + episodeCount;
}

/// ==========================================
/// 首页数据Providers
/// ==========================================

/// 继续观看
final resumeItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getResumeItems();
});

/// 下一集
final nextUpProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getNextUp();
});

/// 媒体库列表（全部，未过滤屏蔽）——供媒体库管理页常驻屏蔽/解除屏蔽用。
final allLibrariesProvider = FutureProvider<List<Library>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getLibraries();
});

/// 媒体库列表（已过滤被屏蔽的）
final librariesProvider = FutureProvider<List<Library>>((ref) async {
  ref.keepAlive();
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final allLibraries = await ref.watch(allLibrariesProvider.future);
  return allLibraries.where((lib) => !hiddenLibraries.contains(lib.id)).toList();
});

/// 最新添加（按媒体库）
final latestItemsProvider = FutureProvider.family<List<MediaItem>, String>((ref, libraryId) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getLatestItems(libraryId, limit: 20);
});

/// 随机推荐
final randomRecommendationsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);
  return await api.home.getRandomRecommendations();
});

final embyMediaCountsProvider = FutureProvider<EmbyMediaCounts>((ref) async {
  ref.keepAlive();
  final api = ref.watch(apiClientProvider);

  try {
    final counts = await api.home.getMediaCounts();
    return EmbyMediaCounts(
      movieCount: counts.movieCount,
      episodeCount: counts.episodeCount,
      itemCount: counts.itemCount,
    );
  } catch (error, stackTrace) {
    debugPrint('[MediaCountsProvider] Failed to load media counts: $error');
    debugPrintStack(
      label: '[MediaCountsProvider] Stack trace',
      stackTrace: stackTrace,
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
});

/// ==========================================
/// 媒体详情Providers
/// ==========================================

/// 媒体项详情
///
/// 内存优化：autoDispose + 有界 LRU 保活（见 [_metadataKeepAlive]）。离开页面后
/// 仍保留最近若干份在内存——返回秒开、不重新联网；超出上限的最旧项被回收，
/// 内存恒定有界。之前全量 keepAlive，浏览每部剧都把详情/季/集/演员/相似永久钉死，
/// 重度浏览必然 OOM（移动/TV 尤甚）。
final mediaItemProvider = FutureProvider.autoDispose.family<MediaItem, String>((ref, itemId) async {
  _metadataKeepAlive.retain('item:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getItemDetails(itemId);
});

/// 相似推荐
final similarItemsProvider = FutureProvider.autoDispose.family<List<MediaItem>, String>((ref, itemId) async {
  _metadataKeepAlive.retain('similar:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSimilarItems(itemId);
});

/// 季列表
final seasonsProvider = FutureProvider.autoDispose.family<List<Season>, String>((ref, seriesId) async {
  _metadataKeepAlive.retain('seasons:$seriesId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSeasons(seriesId);
});

/// 集列表
final episodesProvider = FutureProvider.autoDispose.family<List<Episode>, ({String seriesId, String? seasonId})>(
  (ref, params) async {
    _metadataKeepAlive.retain('episodes:${params.seriesId}:${params.seasonId}', ref);
    final api = ref.watch(apiClientProvider);
    return await api.media.getEpisodes(params.seriesId, seasonId: params.seasonId);
  },
);

/// 演职人员
final personsProvider = FutureProvider.autoDispose.family<List<Person>, String>((ref, itemId) async {
  _metadataKeepAlive.retain('persons:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  final item = await api.media.getItemDetails(itemId);
  return item.people ?? const <Person>[];
});

/// ==========================================
/// 媒体库详情Providers
/// ==========================================

/// 媒体库详情页的排序偏好（跨页面/退出播放器返回后保持）。
/// 只持久化排序字段本身；类型/标签/年份等筛选仍是每次进页面重置的临时态。
class LibrarySortPref {
  const LibrarySortPref({this.sortBy = 'SortName', this.descending = false});

  final String sortBy;
  final bool descending;
}

/// 排序偏好落盘（SharedPreferences），三端媒体库详情共用。
final librarySortProvider =
    StateNotifierProvider<PreferenceNotifier<LibrarySortPref>, LibrarySortPref>(
        (ref) {
  return PreferenceNotifier<LibrarySortPref>(
    defaultValue: const LibrarySortPref(),
    readValue: (prefs) {
      final by = prefs.getString('wjplayer_library_sort_by');
      if (by == null) return null;
      return LibrarySortPref(
        sortBy: by,
        descending: prefs.getBool('wjplayer_library_sort_desc') ?? false,
      );
    },
    writeValue: (prefs, value) async {
      await prefs.setString('wjplayer_library_sort_by', value.sortBy);
      await prefs.setBool('wjplayer_library_sort_desc', value.descending);
    },
  );
});

/// 媒体库内容
final libraryItemsProvider = FutureProvider.autoDispose.family<
    List<MediaItem>,
    ({
      String libraryId,
      String? sortBy,
      String? sortOrder,
      String? genres,
      String? tags,
      String? studioIds,
      String? studios,
      String? years,
      double? ratingMin,
      double? ratingMax,
    })>(
  (ref, params) async {
    final api = ref.watch(apiClientProvider);
    return await api.library.getLibraryItems(
      libraryId: params.libraryId,
      limit: 0, // 媒体库详情：拉全部（不再截 50），支持一直下滑浏览
      sortBy: params.sortBy,
      sortOrder: params.sortOrder,
      genres: params.genres,
      tags: params.tags,
      studioIds: params.studioIds,
      studios: params.studios,
      years: params.years,
      ratingMin: params.ratingMin,
      ratingMax: params.ratingMax,
    );
  },
);

/// 筛选条件
final filtersProvider = FutureProvider.autoDispose.family<Filters, String>((ref, libraryId) async {
  final api = ref.watch(apiClientProvider);
  return await api.library.getFilters(libraryId);
});

/// 全部合集（BoxSet）——首页底部"合集"栏用，点开复用媒体库详情展示成员。
final collectionsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.library.getCollections();
});

/// ==========================================
/// 收藏 Providers
/// ==========================================

final favoritesRefreshTickProvider = StateProvider<int>((ref) => 0);

final favoriteItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  ref.watch(favoritesRefreshTickProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final api = ref.watch(apiClientProvider);
  final items = await api.favorite.getFavorites();

  return items.where((item) {
    if (item.parentId != null && hiddenLibraries.contains(item.parentId)) {
      return false;
    }
    return item.userData?.isFavorite ?? true;
  }).toList();
});

void refreshFavorites(WidgetRef ref) {
  ref.read(favoritesRefreshTickProvider.notifier).state++;
  ref.invalidate(favoriteItemsProvider);
}

/// ==========================================
/// 搜索Providers
/// ==========================================

/// 搜索关键词
final searchQueryProvider = StateProvider<String>((ref) => '');

/// 聚合搜索开关
final aggregateSearchProvider = StateProvider<bool>((ref) => false);

/// 聚合搜索结果（按服务器分组）。
///
/// 真正的跨服务器搜索：遍历 [serverListProvider] 里**每一台已登录**服务器，
/// 各自用缓存的只读 client **并行**查询并合并；任一服务器失败只记日志并
/// 跳过，不拖垮其余。返回「服务器名 → 命中列表」，供需要分组展示的端使用
/// （移动端按服务器分组、桌面/TV 可平铺）。
///
/// 注：旧实现把聚合委托给 `api.search.searchAggregate()`，但那只查当前 client
/// 指向的单台服务器（等价于普通搜索），是聚合搜索"看似开了却没效果"的根因。
/// **逐台增量**：用 [StreamProvider] + [Stream.fromFutures]，哪台服务器先返回就先 emit
/// 一版累积结果，一台慢/掉线不阻塞其它台（不再 `Future.wait` 等齐才出）。
/// 只保留电影/剧集——聚合搜索面向剧、电影，过滤掉分集/人物等非顶层条目。
final aggregateSearchResultsProvider =
    StreamProvider.autoDispose<Map<String, List<MediaItem>>>((ref) async* {
  final query = ref.watch(searchQueryProvider).trim();
  final servers = ref.watch(serverListProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);

  if (query.isEmpty) {
    yield const <String, List<MediaItem>>{};
    return;
  }

  // 仅搜已登录（authToken 非空）的服务器。
  final targets =
      servers.where((s) => (s.authToken ?? '').isNotEmpty).toList();
  if (targets.isEmpty) {
    yield const <String, List<MediaItem>>{};
    return;
  }

  // 离开搜索页即杀掉在飞的搜索请求，别让服务器继续白算。
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) cancelToken.cancel('search-disposed');
  });

  // 每台一条：查询 → 只留电影/剧集 → 排除隐藏库。单台异常被隔离为空结果 + 日志。
  Future<MapEntry<String, List<MediaItem>>> queryOne(ServerConfig server) async {
    final client = ref.read(serverApiClientProvider(server.id));
    if (client == null) return MapEntry(server.name, const <MediaItem>[]);
    try {
      final items = await client.search.search(query, cancelToken: cancelToken);
      final filtered = items.where((item) {
        if (item.type != 'Movie' && item.type != 'Series') return false;
        if (item.parentId != null &&
            hiddenLibraries.contains(item.parentId)) {
          return false;
        }
        return true;
      }).toList();
      // 打来源标记：让封面/点击解析到正确的服务器（见 MediaItem.sourceServerId）。
      for (final item in filtered) {
        item.sourceServerId = server.id;
      }
      return MapEntry(server.name, filtered);
    } catch (e) {
      AppLogger().w('AggregateSearch', '服务器「${server.name}」搜索失败: $e');
      return MapEntry(server.name, const <MediaItem>[]);
    }
  }

  // 哪台先返回就先显示：Stream.fromFutures 按完成顺序吐结果。每次都按 serverListProvider
  // 原顺序重排后 emit（完成顺序 ≠ 展示顺序），一台掉线不拖累其它台。
  final acc = <String, List<MediaItem>>{};
  var emitted = false;
  await for (final e in Stream.fromFutures(targets.map(queryOne))) {
    if (e.value.isEmpty) continue;
    acc[e.key] = e.value;
    emitted = true;
    yield <String, List<MediaItem>>{
      for (final s in targets)
        if (acc[s.name]?.isNotEmpty ?? false) s.name: acc[s.name]!,
    };
  }
  // 全部服务器都无命中：emit 一次空，让 UI 从 loading 落到「没有找到结果」而非一直转圈。
  if (!emitted) yield const <String, List<MediaItem>>{};
});

/// 排行榜条目在某台服务器上的最佳命中。
class ServerMatchInfo {
  final String serverName;

  /// 最佳匹配项（已打 sourceServerId），供点按跳转。
  final MediaItem item;

  /// 总集数（剧集用 recursiveItemCount/childCount；电影为 null）。
  final int? episodeCount;

  const ServerMatchInfo({
    required this.serverName,
    required this.item,
    this.episodeCount,
  });
}

/// 按标题跨服务器聚合搜索：遍历**每台已登录**服务器，各自挑出与标题最匹配的
/// 一条并解析其总集数。供排行榜条目点按后的详情弹窗展示「哪些服务器有、共几集」。
///
/// 复用 [aggregateSearchResultsProvider] 的并行 + 单台失败隔离思路，但以标题
/// 参数化，且每台只保留一条最佳匹配（避免弹窗信息过载）。不解析分辨率/码率——
/// 剧集要逐集拉流才知道，太贵且意义不大。
///
/// **逐台增量**：StreamProvider + [Stream.fromFutures]，哪台先命中就先 emit，一台
/// 慢/掉线不阻塞其它台（不再 `Future.wait` 等齐才出）。
final rankingCrossServerMatchProvider = StreamProvider.autoDispose
    .family<List<ServerMatchInfo>, String>((ref, title) async* {
  final query = title.trim();
  if (query.isEmpty) {
    yield const <ServerMatchInfo>[];
    return;
  }

  final servers = ref.watch(serverListProvider);
  final targets =
      servers.where((s) => (s.authToken ?? '').isNotEmpty).toList();
  if (targets.isEmpty) {
    yield const <ServerMatchInfo>[];
    return;
  }

  // 关掉排行榜弹窗即杀掉在飞的跨服搜索请求。
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) cancelToken.cancel('ranking-match-disposed');
  });

  Future<ServerMatchInfo?> matchOne(ServerConfig server) async {
    final client = ref.read(serverApiClientProvider(server.id));
    if (client == null) return null;
    try {
      final items = await client.search.search(query, cancelToken: cancelToken);
      if (items.isEmpty) return null;
      // 打来源标记：让封面/点击解析到正确的服务器。
      for (final item in items) {
        item.sourceServerId = server.id;
      }
      // 挑最佳匹配：优先名称完全一致（忽略大小写），否则第一条剧集/电影，否则第一条。
      final lower = query.toLowerCase();
      final best = items.firstWhere(
        (i) => i.name.toLowerCase() == lower,
        orElse: () => items.firstWhere(
          (i) => i.type == 'Series' || i.type == 'Movie',
          orElse: () => items.first,
        ),
      );

      final episodeCount = best.recursiveItemCount ?? best.childCount;

      return ServerMatchInfo(
        serverName: server.name,
        item: best,
        episodeCount: episodeCount,
      );
    } catch (e) {
      AppLogger().w('RankingMatch', '服务器「${server.name}」搜索失败: $e');
      return null;
    }
  }

  // 哪台先命中就先显示：按完成顺序累积，每次按 serverListProvider 原顺序重排后 emit。
  final acc = <String, ServerMatchInfo>{};
  var emitted = false;
  await for (final r in Stream.fromFutures(targets.map(matchOne))) {
    if (r == null) continue;
    acc[r.serverName] = r;
    emitted = true;
    yield <ServerMatchInfo>[
      for (final s in targets)
        if (acc[s.name] != null) acc[s.name]!,
    ];
  }
  if (!emitted) yield const <ServerMatchInfo>[];
});

/// 搜索结果（平铺）。聚合开关打开时跨所有服务器搜索并合并，否则只搜当前服务器。
final searchResultsProvider = FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final isAggregate = ref.watch(aggregateSearchProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);

  if (query.isEmpty) return [];

  if (isAggregate) {
    // 跨服务器聚合后平铺（桌面/TV 用平铺列表展示）。
    final grouped = await ref.watch(aggregateSearchResultsProvider.future);
    return grouped.values.expand((list) => list).toList();
  }

  final api = ref.watch(apiClientProvider);
  final results = await api.search.search(query);

  // 排除被屏蔽媒体库的结果（通过parentId匹配）
  return results.where((item) {
    if (item.parentId != null && hiddenLibraries.contains(item.parentId)) return false;
    return true;
  }).toList();
});

/// 搜索历史
final searchHistoryProvider = StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super(_load());

  static const _prefKey = 'wjplayer_search_history';

  static List<String> _load() {
    try {
      return AppPreferencesStore.instance.getStringList(_prefKey) ?? <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  void _persist() {
    try {
      AppPreferencesStore.instance.setStringList(_prefKey, state);
    } catch (_) {
      // 持久化失败不影响内存中的历史。
    }
  }

  void addQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    state = [
      q,
      ...state.where((e) => e != q),
    ].take(20).toList();
    _persist();
  }

  void removeQuery(String query) {
    state = state.where((q) => q != query).toList();
    _persist();
  }

  void clear() {
    state = [];
    _persist();
  }
}

/// ==========================================
/// 播放Providers
/// ==========================================

/// 播放信息
/// 详情页 / 播放器设置面板「媒体信息 + 版本 + 轨道列表」用的数据源：只 GET 条目已缓存
/// 的 MediaSources/MediaStreams（`Fields` 查询），**不**带 IsPlayback / AutoOpenLiveStream，
/// 绝不为了展示就让服务端开流 ffprobe（尤其 strm/网盘，白探一次很费服务器）。服务端返回
/// 什么就展示什么、没返回就没有；**真正播放**走的是播放页里直接调用的
/// [PlaybackApi.getPlaybackInfo]（不经本 provider），该完整流程照旧。
final playbackInfoProvider = FutureProvider.autoDispose.family<PlaybackInfo, String>((ref, itemId) async {
  _metadataKeepAlive.retain('playback:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  final sources = await api.media.getItemMediaSources(itemId);
  return PlaybackInfo(itemId: itemId, mediaSources: sources);
});

/// 当前播放项
final currentPlayingItemProvider = StateProvider<MediaItem?>((ref) => null);

/// 播放进度
final playbackProgressProvider = StateProvider<double>((ref) => 0.0);

/// 播放状态
final isPlayingProvider = StateProvider<bool>((ref) => false);

/// 音量
final volumeProvider = StateProvider<double>((ref) => 1.0);

/// 播放速度
final playbackSpeedProvider = StateProvider<double>((ref) => 1.0);

/// 字幕轨道
final subtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 次字幕轨道（第二个字幕）
final secondarySubtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 音频轨道
final audioTrackProvider = StateProvider<int?>((ref) => null);

/// 当前选择的媒体源
final selectedMediaSourceProvider = StateProvider<String?>((ref) => null);
