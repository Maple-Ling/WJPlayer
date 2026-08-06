import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_interfaces.dart';
import '../api/discover/discover_models.dart';
import 'discover_providers.dart';
import '../providers/app_providers.dart';
import '../providers/reveal_hidden_provider.dart';
import '../services/app_logger.dart';
import '../services/home_data_cache.dart';
import '../sources/feiniu_backend.dart';
import '../utils/track_preference.dart';
import '../sources/media_source_backend.dart';

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
  final int seriesCount;
  final int episodeCount;
  final int? itemCount;

  const EmbyMediaCounts({
    required this.movieCount,
    this.seriesCount = 0,
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
  final server = ref.watch(currentServerProvider);
  if (server == null) return <MediaItem>[];

  return await HomeCacheLoader.load<List<MediaItem>>(
    serverId: server.id,
    dataType: 'resume',
    decode: (json) =>
        (json as List).map((e) => MediaItem.fromJson(e)).toList(),
    encode: (value) => value.map((item) => item.toJson()).toList(),
    load: () async {
      final api = ref.watch(apiClientProvider);
      return await api.home.getResumeItems();
    },
  );
});

/// 下一集
final nextUpProvider = FutureProvider<List<MediaItem>>((ref) async {
  final server = ref.watch(currentServerProvider);
  if (server == null) return <MediaItem>[];

  final api = ref.watch(apiClientProvider);
  return await api.home.getNextUp();
});

/// 媒体库列表（全部，未过滤屏蔽）——供媒体库管理页常驻屏蔽/解除屏蔽用。
final allLibrariesProvider = FutureProvider<List<Library>>((ref) async {
  ref.keepAlive();
  final server = ref.watch(currentServerProvider);
  if (server == null) return <Library>[];

  return await HomeCacheLoader.load<List<Library>>(
    serverId: server.id,
    dataType: 'libraries',
    decode: (json) => (json as List).map((e) => Library.fromJson(e)).toList(),
    encode: (value) => value.map((item) => item.toJson()).toList(),
    load: () async {
      final api = ref.watch(apiClientProvider);
      return await api.home.getLibraries();
    },
  );
});

/// 媒体库列表（已过滤被屏蔽的）
final librariesProvider = FutureProvider<List<Library>>((ref) async {
  ref.keepAlive();
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final allLibraries = await ref.watch(allLibrariesProvider.future);
  return allLibraries
      .where((lib) => !hiddenLibraries.contains(lib.id))
      .toList();
});

/// 最新添加（按媒体库）
final latestItemsProvider =
    FutureProvider.family<List<MediaItem>, String>((ref, libraryId) async {
  ref.keepAlive();
  final server = ref.watch(currentServerProvider);
  if (server == null) return <MediaItem>[];

  return await HomeCacheLoader.load<List<MediaItem>>(
    serverId: server.id,
    dataType: 'latest:$libraryId',
    decode: (json) =>
        (json as List).map((e) => MediaItem.fromJson(e)).toList(),
    encode: (value) => value.map((item) => item.toJson()).toList(),
    load: () async {
      final api = ref.watch(apiClientProvider);
      return await api.home.getLatestItems(libraryId, limit: 20);
    },
  );
});

/// 随机推荐
final randomRecommendationsProvider =
    FutureProvider<List<MediaItem>>((ref) async {
  ref.keepAlive();
  final server = ref.watch(currentServerProvider);
  if (server == null) return <MediaItem>[];

  return await HomeCacheLoader.load<List<MediaItem>>(
    serverId: server.id,
    dataType: 'random',
    decode: (json) =>
        (json as List).map((e) => MediaItem.fromJson(e)).toList(),
    encode: (value) => value.map((item) => item.toJson()).toList(),
    load: () async {
      final api = ref.watch(apiClientProvider);
      return await api.home.getRandomRecommendations();
    },
  );
});

final embyMediaCountsProvider = FutureProvider<EmbyMediaCounts>((ref) async {
  ref.keepAlive();
  final server = ref.watch(currentServerProvider);
  if (server == null) {
    return const EmbyMediaCounts(
      movieCount: 0,
      seriesCount: 0,
      episodeCount: 0,
      itemCount: null,
    );
  }

  return await HomeCacheLoader.load<EmbyMediaCounts>(
    serverId: server.id,
    dataType: 'counts',
    decode: (json) => EmbyMediaCounts(
      movieCount: json['movieCount'] as int? ?? 0,
      seriesCount: json['seriesCount'] as int? ?? 0,
      episodeCount: json['episodeCount'] as int? ?? 0,
      itemCount: json['itemCount'] as int?,
    ),
    encode: (value) => {
      'movieCount': value.movieCount,
      'seriesCount': value.seriesCount,
      'episodeCount': value.episodeCount,
      'itemCount': value.itemCount,
    },
    load: () async {
      final api = ref.watch(apiClientProvider);
      final counts = await api.home.getMediaCounts();
      return EmbyMediaCounts(
        movieCount: counts.movieCount,
        seriesCount: counts.seriesCount,
        episodeCount: counts.episodeCount,
        itemCount: counts.itemCount,
      );
    },
  );
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
final mediaItemProvider =
    FutureProvider.autoDispose.family<MediaItem, String>((ref, itemId) async {
  _metadataKeepAlive.retain('item:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getItemDetails(itemId);
});

/// 相似推荐
final similarItemsProvider = FutureProvider.autoDispose
    .family<List<MediaItem>, String>((ref, itemId) async {
  _metadataKeepAlive.retain('similar:$itemId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSimilarItems(itemId);
});

/// 季列表
final seasonsProvider = FutureProvider.autoDispose
    .family<List<Season>, String>((ref, seriesId) async {
  _metadataKeepAlive.retain('seasons:$seriesId', ref);
  final api = ref.watch(apiClientProvider);
  return await api.media.getSeasons(seriesId);
});

/// 集列表
final episodesProvider = FutureProvider.autoDispose
    .family<List<Episode>, ({String seriesId, String? seasonId})>(
  (ref, params) async {
    _metadataKeepAlive.retain(
        'episodes:${params.seriesId}:${params.seasonId}', ref);
    final api = ref.watch(apiClientProvider);
    return await api.media
        .getEpisodes(params.seriesId, seasonId: params.seasonId);
  },
);

/// 演职人员
final personsProvider = FutureProvider.autoDispose
    .family<List<Person>, String>((ref, itemId) async {
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
    final useExternalRating = params.sortBy == 'ExternalRating';
    final items = await api.library.getLibraryItems(
      libraryId: params.libraryId,
      limit: 0, // 媒体库详情：拉全部（不再截 50），支持一直下滑浏览
      sortBy: useExternalRating ? null : params.sortBy,
      sortOrder: params.sortOrder,
      genres: params.genres,
      tags: params.tags,
      studioIds: params.studioIds,
      studios: params.studios,
      years: params.years,
      ratingMin: params.ratingMin,
      ratingMax: params.ratingMax,
    );
    if (!useExternalRating || items.length < 2) return items;

    final source = ref.watch(reviewSourceProvider);
    final service = ref.watch(discoverServiceProvider);
    final scores = <String, double?>{};
    // 每批最多 6 个请求，避免大媒体库瞬间压垮豆瓣/TMDB/IMDb。
    for (var start = 0; start < items.length; start += 6) {
      final chunk = items.skip(start).take(6).toList();
      final values = await Future.wait(
        chunk.map((item) => service.ratingFor(source, item)),
      );
      for (var i = 0; i < chunk.length; i++) {
        scores[chunk[i].id] = values[i];
      }
    }
    final sorted = [...items];
    final descending = params.sortOrder != 'Ascending';
    sorted.sort((a, b) {
      final av = scores[a.id];
      final bv = scores[b.id];
      if (av == null && bv == null) return a.name.compareTo(b.name);
      if (av == null) return 1;
      if (bv == null) return -1;
      final result = av.compareTo(bv);
      return descending ? -result : result;
    });
    return sorted;
  },
);

/// 筛选条件
final filtersProvider =
    FutureProvider.autoDispose.family<Filters, String>((ref, libraryId) async {
  final api = ref.watch(apiClientProvider);
  return await api.library.getFilters(libraryId);
});

/// 全部合集（BoxSet）——首页底部"合集"栏用，点开复用媒体库详情展示成员。
final collectionsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final server = ref.watch(currentServerProvider);
  if (server == null) return <MediaItem>[];

  return await HomeCacheLoader.load<List<MediaItem>>(
    serverId: server.id,
    dataType: 'collections',
    decode: (json) =>
        (json as List).map((e) => MediaItem.fromJson(e)).toList(),
    encode: (value) => value.map((item) => item.toJson()).toList(),
    load: () async {
      final api = ref.watch(apiClientProvider);
      return await api.library.getCollections();
    },
  );
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

/// 飞牛源搜索结果。飞牛是独立媒体源协议，不能复用 Emby ApiClient；结果保留
/// SourceEntry 的 GUID、图片 URL 和鉴权头，点击后直接进入飞牛详情页。
final feiniuSearchResultsProvider = FutureProvider.autoDispose
    .family<List<SourceEntry>, ({String serverId, String query})>((ref, args) async {
  final server = ref
      .watch(serverListProvider)
      .where((entry) => entry.id == args.serverId)
      .firstOrNull;
  if (server == null || server.sourceKind != SourceKind.feiniu) return const [];
  final keyword = args.query.trim();
  if (keyword.isEmpty) return const [];
  final results = await FeiniuBackend().search(server, keyword);
  return results.where(_isTopLevelFeiniuEntry).toList();
});

bool _isTopLevelFeiniuEntry(SourceEntry entry) {
  final type = entry.raw?['type']?.toString().trim().toLowerCase();
  // 部分 fnOS 搜索接口省略 type，但仍返回可播放顶层条目；只明确排除分集/季/目录。
  if (type == null || type.isEmpty) return entry.id.isNotEmpty;
  // 顶层可播条目：电影 / 剧集 / 视频文件（文件浏览型源常以 video 标识顶层条目）。
  return type == 'movie' ||
      type == 'tv' ||
      type == 'series' ||
      type == 'video';
}

/// 聚合搜索开关
final aggregateSearchProvider = StateProvider<bool>((ref) => false);

class FeiniuSearchGroup {
  const FeiniuSearchGroup({required this.server, required this.entries});
  final ServerConfig server;
  final List<SourceEntry> entries;
}

/// 聚合搜索中的飞牛分组。与 Emby 查询并行，任一飞牛服务器失败仅跳过该组。
/// 聚合搜索公共链路的输出：Emby 分组 + 飞牛分组。
class AggregateSearchOutcome {
  const AggregateSearchOutcome({
    this.embyGroups = const {},
    this.feiniuGroups = const [],
  });

  /// 「服务器名 → 命中列表」（Emby，已过滤隐藏服务器/隐藏库/顶层类型）。
  final Map<String, List<MediaItem>> embyGroups;

  /// 飞牛分组（已过滤隐藏服务器/顶层条目）。
  final List<FeiniuSearchGroup> feiniuGroups;
}

/// 聚合搜索**公共链路**（参数化 query）。
///
/// 首页状态栏聚合搜索、ABCD 详情页「播放资源」搜索统一从这里取数，
/// 所有安全过滤规则只维护一份：
/// 1. 隐藏属性的服务器（server.hidden == true）一律排除，不出现在任何结果里；
/// 2. 未登录服务器（Emby 无 authToken / 飞牛无凭据）排除；
/// 3. Emby 仅保留 Movie/Series 顶层条目，并排除隐藏库（hiddenLibraries）；
/// 4. 飞牛仅保留顶层条目（feiniuSearchResultsProvider 内部已过滤）；
/// 5. 命中项打 sourceServerId 标记，供封面/点击解析回正确服务器；
/// 6. 单台失败只记日志跳过，不拖垮其余；页面销毁即取消在途 Emby 请求。
///
/// **逐台增量**：用 StreamProvider + Stream.fromFutures，哪台服务器先返回
/// 就先 emit 一版累积结果，一台慢/掉线不阻塞其它台（不再 Future.wait 等齐才出）。
final aggregateSearchByQueryProvider = StreamProvider.autoDispose
    .family<AggregateSearchOutcome, String>((ref, rawQuery) async* {
  final query = rawQuery.trim();
  if (query.isEmpty) {
    yield const AggregateSearchOutcome();
    return;
  }
  final servers = ref.watch(serverListProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  // 安全过滤：隐藏属性的服务器默认不参与聚合搜索；服务器列表「三击标题」
  // 显示隐藏服务器（revealHiddenServersProvider=true）后，带 hidden 标记的
  // 服务器同样可被搜索（与列表里实际能看到的一致）。
  final revealHidden = ref.watch(revealHiddenServersProvider);
  final visibleServers = servers
      .where((server) => server.hidden != true || revealHidden)
      .toList();
  final embyTargets = visibleServers
      .where((server) =>
          server.sourceKind == SourceKind.emby &&
          (server.authToken ?? '').isNotEmpty)
      .toList();
  final feiniuTargets = visibleServers
      .where((server) =>
          server.sourceKind == SourceKind.feiniu &&
          ((server.authToken ?? '').isNotEmpty ||
              (server.username ?? '').isNotEmpty))
      .toList();
  if (embyTargets.isEmpty && feiniuTargets.isEmpty) {
    yield const AggregateSearchOutcome();
    return;
  }

  // 离开页面即杀掉在飞的搜索请求，别让服务器继续白算。
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('aggregate-search-disposed');
    }
  });

  // Emby：逐台并行，只留电影/剧集，排除隐藏库，打来源标记。
  Future<MapEntry<String, List<MediaItem>>> embyOne(ServerConfig server) async {
    final client = ref.read(serverApiClientProvider(server.id));
    if (client == null) {
      return MapEntry(server.name, const <MediaItem>[]);
    }
    try {
      final items = await client.search.search(query, cancelToken: cancelToken);
      final filtered = items.where((item) {
        if (item.type != 'Movie' && item.type != 'Series') return false;
        if (item.parentId != null && hiddenLibraries.contains(item.parentId)) {
          return false;
        }
        return true;
      }).toList();
      for (final item in filtered) {
        item.sourceServerId = server.id;
      }
      return MapEntry(server.name, filtered);
    } catch (e) {
      AppLogger().w('AggregateSearch', '服务器「${server.name}」搜索失败: $e');
      return MapEntry(server.name, const <MediaItem>[]);
    }
  }

  // 飞牛：逐台并行（feiniuSearchResultsProvider 内部已过滤顶层条目）。
  Future<FeiniuSearchGroup> feiniuOne(ServerConfig server) async {
    try {
      final entries = await ref.read(feiniuSearchResultsProvider(
        (serverId: server.id, query: query),
      ).future);
      return FeiniuSearchGroup(server: server, entries: entries);
    } catch (error) {
      AppLogger().w('AggregateSearch', '服务器「${server.name}」飞牛搜索失败: $error');
      return FeiniuSearchGroup(server: server, entries: const []);
    }
  }

  final futures = <Future<Object>>[
    ...embyTargets.map(embyOne),
    ...feiniuTargets.map(feiniuOne),
  ];
  final accEmby = <String, List<MediaItem>>{};
  final accFeiniu = <FeiniuSearchGroup>[];
  var emitted = false;
  // 哪台先返回就先显示：完成顺序 ≠ 展示顺序，每次按服务器原顺序重排后 emit。
  await for (final e in Stream.fromFutures(futures)) {
    if (e is MapEntry<String, List<MediaItem>>) {
      if (e.value.isEmpty) continue;
      accEmby[e.key] = e.value;
    } else if (e is FeiniuSearchGroup) {
      if (e.entries.isEmpty) continue;
      accFeiniu.add(e);
    }
    emitted = true;
    // 结果组装层的防御性校验：targets 在请求开始时就已按「隐藏或未三击显示」
    // 滤除，这里在 emit 前再次拦截（与 targets 同口径：!hidden || revealHidden），
    // 双保险杜绝任何不应展示的服务器被展示——即使请求期间服务器属性发生变化
    // 也不放行。
    yield AggregateSearchOutcome(
      embyGroups: {
        for (final s in embyTargets)
          if ((s.hidden != true || revealHidden) &&
              (accEmby[s.name]?.isNotEmpty ?? false))
            s.name: accEmby[s.name]!,
      },
      feiniuGroups: [
        for (final s in feiniuTargets)
          if ((s.hidden != true || revealHidden) &&
              accFeiniu.any((g) => g.server.id == s.id))
            accFeiniu.firstWhere((g) => g.server.id == s.id),
      ],
    );
  }
  // 全部服务器都无命中：emit 一次空，让 UI 从 loading 落到「没有找到结果」而非一直转圈。
  if (!emitted) yield const AggregateSearchOutcome();
});

/// 聚合搜索中的飞牛分组。与 Emby 查询并行，任一飞牛服务器失败仅跳过该组。
/// 过滤规则与公共链路一致：隐藏服务器（未三击显示时）/ 未登录一律排除。
final aggregateFeiniuSearchProvider = FutureProvider.autoDispose
    .family<List<FeiniuSearchGroup>, String>((ref, rawQuery) async {
  final query = rawQuery.trim();
  if (query.isEmpty) return const [];
  final revealHidden = ref.watch(revealHiddenServersProvider);
  final servers = ref
      .watch(serverListProvider)
      .where((server) =>
          (server.hidden != true || revealHidden) &&
          server.sourceKind == SourceKind.feiniu &&
          ((server.authToken ?? '').isNotEmpty ||
              (server.username ?? '').isNotEmpty))
      .toList();
  final groups = await Future.wait(servers.map((server) async {
    try {
      final entries = await ref.read(feiniuSearchResultsProvider(
        (serverId: server.id, query: query),
      ).future);
      return FeiniuSearchGroup(server: server, entries: entries);
    } catch (error) {
      AppLogger().w('AggregateSearch', '服务器「${server.name}」飞牛搜索失败: $error');
      return FeiniuSearchGroup(server: server, entries: const []);
    }
  }));
  return groups.where((group) => group.entries.isNotEmpty).toList();
});

/// 聚合搜索结果（按服务器分组）——转调聚合搜索公共链路，仅取 Emby 分组。
///
/// 真正的跨服务器搜索：公共链路遍历 serverListProvider 里每一台**已登录且
/// 未隐藏**服务器，各自用缓存的只读 client **并行**查询并合并；任一服务器
/// 失败只记日志并跳过，不拖垮其余。返回「服务器名 → 命中列表」，供需要
/// 分组展示的端使用（移动端按服务器分组、桌面/TV 可平铺）。
///
/// 注：旧实现把聚合委托给 `api.search.searchAggregate()`，但那只查当前 client
/// 指向的单台服务器（等价于普通搜索），是聚合搜索"看似开了却没效果"的根因。
/// 聚合搜索结果（按服务器分组）。
///
/// 真正的跨服务器搜索：遍历 [serverListProvider] 里**每一台已登录且未隐藏**
/// 服务器，各自用缓存的只读 client **并行**查询并合并；任一服务器失败只记
/// 日志并跳过，不拖垮其余。返回「服务器名 → 命中列表」，供需要分组展示的端
/// 使用（移动端按服务器分组、桌面/TV 可平铺）。
///
/// 注：旧实现把聚合委托给 `api.search.searchAggregate()`，但那只查当前 client
/// 指向的单台服务器（等价于普通搜索），是聚合搜索"看似开了却没效果"的根因。
/// **逐台增量**：用 [StreamProvider] + [Stream.fromFutures]，哪台服务器先返回就先
/// emit 一版累积结果，一台慢/掉线不阻塞其它台（不再 `Future.wait` 等齐才出）。
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

  // Emby 与飞牛使用不同协议；这里仅处理 Emby，飞牛由
  // aggregateFeiniuSearchProvider 并行查询并在 UI 合并。
  final revealHidden = ref.watch(revealHiddenServersProvider);
  final targets = servers
      .where((s) =>
          s.sourceKind == SourceKind.emby &&
          (s.hidden != true || revealHidden) &&
          (s.authToken ?? '').isNotEmpty)
      .toList();
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
  Future<MapEntry<String, List<MediaItem>>> queryOne(
      ServerConfig server) async {
    final client = ref.read(serverApiClientProvider(server.id));
    if (client == null) return MapEntry(server.name, const <MediaItem>[]);
    try {
      final items = await client.search.search(query, cancelToken: cancelToken);
      final filtered = items.where((item) {
        if (item.type != 'Movie' && item.type != 'Series') return false;
        if (item.parentId != null && hiddenLibraries.contains(item.parentId)) {
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

  /// Emby 最佳匹配项；飞牛也提供合成 MediaItem 供标题/类型统一展示。
  final MediaItem item;

  /// 飞牛匹配时保留完整 SourceEntry（GUID、图片鉴权头、原始详情字段）。
  final SourceEntry? sourceEntry;
  final String? sourceServerId;

  /// 总集数（剧集用 recursiveItemCount/childCount；电影为 null）。
  final int? episodeCount;

  /// Emby 服务器资源的**完整媒体流详情**（getItemMediaSources；Movie 才有，
  /// Series 需逐集拉流，为 null）。资源卡/聚合胶囊显示分辨率/编码/HDR/码率/
  /// 大小，与详情页底部媒体信息同源；缺失时 UI 回退 [item] 的搜索摘要。
  final MediaSource? mediaSource;

  /// 飞牛服务器资源的**完整媒体流详情**（mediaDetails：play/info + /stream；
  /// movie/episode 才有，tv 需逐集拉流，为 null）。video/file 为归一化 key，
  /// 与详情页底部媒体信息（_buildStreamInfoCards）完全一致。
  final FeiniuMediaDetails? feiniuDetails;

  const ServerMatchInfo({
    required this.serverName,
    required this.item,
    this.sourceEntry,
    this.sourceServerId,
    this.episodeCount,
    this.mediaSource,
    this.feiniuDetails,
  });
}

/// 跨服务器最佳匹配（ABCD 详情页「播放资源」区、播放器聚合菜单共用）。
///
/// **独立逐台并行查询（与搜索页聚合链路同款逻辑）**：遍历每台**已登录且
/// 未隐藏**服务器，各自搜索并挑一条最佳，单台失败只记日志跳过，不拖垮其余。
/// 过滤规则与首页状态栏聚合搜索一致：隐藏服务器（server.hidden == true）/
/// 未登录 / 隐藏库一律排除。
/// - Emby：仅保留 Movie/Series 顶层条目（search API 的 IncludeItemTypes
///   硬编码 Movie,Series，单集不可达，不做 Episode 分支）。精确同名优先，
///   否则取第一条；
/// - 飞牛：归一化评分（精确 3 分 > 互相包含 2 分，episode/season 降权、
///   tv/movie/series 加分），避免「名称近似但货不对板」的误匹配。
/// 每台「搜索+匹配+详情」完成后即增量 emit（Stream.fromFutures，哪台先命中
/// 先显示，按服务器原顺序重排）；详情失败只丢详情不丢匹配（胶囊回退搜索摘要）。
final rankingCrossServerMatchProvider = StreamProvider.autoDispose
    .family<List<ServerMatchInfo>, String>((ref, title) async* {
  final query = title.trim();
  if (query.isEmpty) {
    yield const <ServerMatchInfo>[];
    return;
  }
  final servers = ref.watch(serverListProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  // 隐藏服务器默认排除；服务器列表三击显示（revealHiddenServersProvider）
  // 后同样参与跨服匹配（与列表可见性一致）。
  final revealHidden = ref.watch(revealHiddenServersProvider);
  final targets = servers
      .where((s) =>
          (s.hidden != true || revealHidden) &&
          (s.sourceKind == SourceKind.emby ||
              s.sourceKind == SourceKind.feiniu) &&
          ((s.authToken ?? '').isNotEmpty ||
              (s.sourceKind == SourceKind.feiniu &&
                  (s.username ?? '').isNotEmpty)))
      .toList();
  if (targets.isEmpty) {
    yield const <ServerMatchInfo>[];
    return;
  }

  // 离开详情页/关闭聚合菜单即杀掉在飞的跨服搜索请求。
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) cancelToken.cancel('ranking-match-disposed');
  });

  Future<ServerMatchInfo?> matchOne(ServerConfig server) async {
    try {
      if (server.sourceKind == SourceKind.feiniu) {
        final entries = await ref.read(feiniuSearchResultsProvider(
          (serverId: server.id, query: query),
        ).future);
        final picked = _pickBestFeiniuMatch(entries, query);
        if (picked == null) return null;
        picked.item.sourceServerId = server.id;
        // 拉飞牛完整媒体流详情（movie/episode；tv 返回 null 让胶囊回退摘要）。
        final details = await _loadFeiniuMediaDetails(
            ref, server.id, picked.entry);
        return ServerMatchInfo(
          serverName: server.name,
          item: picked.item,
          sourceEntry: picked.entry,
          sourceServerId: server.id,
          episodeCount: picked.episodeCount,
          feiniuDetails: details,
        );
      }
      final client = ref.read(serverApiClientProvider(server.id));
      if (client == null) return null;
      var items = await client.search.search(query, cancelToken: cancelToken);
      if (items.isEmpty) {
        // 兜底：主 query 无结果时按候选列表重搜——去年份/分辨率后缀
        // （飞牛条目名常见「凡人修仙传.2023.1080p」）与冒号副标题截断
        // （「凡人修仙传:风起天南」→「凡人修仙传」），Emby 完整包含匹配
        // 对带后缀/副标题的 query 必空，干净主干才能命中。
        for (final candidate in searchTitleCandidates(query)) {
          items = await client.search.search(candidate,
              cancelToken: cancelToken);
          if (items.isNotEmpty) break;
        }
      }
      // Emby search API 的 IncludeItemTypes 硬编码 Movie,Series，
      // 返回里不可能有 Episode，只保留 Movie/Series 顶层条目即可。
      final topLevel = items.where((item) {
        return item.type == 'Movie' || item.type == 'Series';
      }).where((item) {
        // 排除隐藏库（与搜索页聚合同规则）。
        if (item.parentId != null && hiddenLibraries.contains(item.parentId)) {
          return false;
        }
        return true;
      }).toList();
      if (topLevel.isEmpty) return null;
      for (final item in topLevel) {
        item.sourceServerId = server.id;
      }
      final lower = query.toLowerCase();
      final best = topLevel.firstWhere(
        (i) => i.name.toLowerCase() == lower,
        orElse: () => topLevel.first,
      );
      // 拉 Emby 完整媒体流详情（仅 Movie；Series 返回 null 让胶囊回退摘要）。
      final mediaSource = await _loadEmbyMediaSource(ref, server.id, best);
      return ServerMatchInfo(
        serverName: server.name,
        item: best,
        episodeCount: best.recursiveItemCount ?? best.childCount,
        mediaSource: mediaSource,
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

/// 拉取 Emby 服务器资源的完整媒体流详情（仅 Movie；Series 需逐集拉流，
/// 返回 null 让胶囊回退搜索摘要）。
Future<MediaSource?> _loadEmbyMediaSource(
    Ref ref, String serverId, MediaItem item) async {
  if (item.type != 'Movie') return null;
  final client = ref.read(serverApiClientProvider(serverId));
  if (client == null) return null;
  try {
    final sources = await client.media.getItemMediaSources(item.id);
    return sources.isEmpty ? null : sources.first;
  } catch (_) {
    return null; // 单台详情失败不影响匹配结果本身
  }
}

/// 拉取飞牛服务器资源的完整媒体流详情（仅 movie/episode；tv 需逐集拉流）。
/// 返回的 FeiniuMediaDetails.video/file 为归一化 key，与详情页底部一致。
Future<FeiniuMediaDetails?> _loadFeiniuMediaDetails(
    Ref ref, String serverId, SourceEntry entry) async {
  final rawType = (entry.raw?['type']?.toString() ?? '').toLowerCase();
  if (rawType == 'tv') return null;
  ServerConfig? server;
  for (final s in ref.read(serverListProvider)) {
    if (s.id == serverId) {
      server = s;
      break;
    }
  }
  if (server == null) return null;
  try {
    return await FeiniuBackend().mediaDetails(server, entry);
  } catch (_) {
    return null;
  }
}

/// 飞牛最佳匹配：归一化评分。返回命中的 SourceEntry 与合成 MediaItem。
({SourceEntry entry, MediaItem item, int? episodeCount})?
    _pickBestFeiniuMatch(List<SourceEntry> playable, String query) {
  if (playable.isEmpty) return null;
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[\s\-_.:()（）【】'\x22]+"), '');
  final target = norm(query);
  var best = playable.first;
  var bestScore = -1;
  for (final entry in playable) {
    final name = norm(entry.name);
    final type = (entry.raw?['type']?.toString() ?? '').toLowerCase();
    int score;
    if (name.isNotEmpty && name == target) {
      score = 3;
    } else if (name.isNotEmpty &&
        (name.contains(target) || target.contains(name))) {
      score = 2;
    } else {
      continue;
    }
    // 顶层剧集/电影优先；明确的分集降权（避免选中单集当整剧）。
    if (type == 'episode' || type == 'season') score -= 2;
    if (type == 'tv' || type == 'series' || type == 'movie') score += 1;
    if (score > bestScore) {
      bestScore = score;
      best = entry;
    }
  }
  final raw = best.raw ?? const <String, dynamic>{};
  final rawType = '${raw['type'] ?? ''}'.toLowerCase();
  final type = rawType == 'episode'
      ? 'Episode'
      : rawType == 'tv' || rawType == 'series'
          ? 'Series'
          : 'Movie';
  final item = MediaItem(
    id: best.id,
    name: best.name,
    type: type,
    providerIds: {
      for (final pair in [
        ('tmdb', raw['tmdb_id'] ?? raw['tmdb']),
        ('imdb', raw['imdb_id'] ?? raw['imdb']),
        ('douban', raw['douban_id'] ?? raw['douban']),
      ])
        if (pair.$2?.toString().trim().isNotEmpty == true)
          pair.$1: pair.$2.toString(),
    },
  );
  return (
    entry: best,
    item: item,
    episodeCount: (raw['episode_count'] as num?)?.toInt(),
  );
}

/// 搜索结果（平铺）。聚合开关打开时跨所有服务器搜索并合并，否则只搜当前服务器。
final searchResultsProvider =
    FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final isAggregate = ref.watch(aggregateSearchProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);

  if (query.isEmpty) return [];

  if (isAggregate) {
    // 聚合模式的展示由 UI 层独立渲染（搜索页 _buildAggregateResults：
    // Emby 分组 + 飞牛分组并行展示），不依赖这里的平铺结果。
    // 注意：不能 watch aggregateSearchResultsProvider.future —— 它是逐台
    // 增量的无限流（async* 永不 close），.future 永不 resolve 会导致聚合
    // 搜索永远 loading（"聚合搜索失效"根因）。此处直接返回空列表即可。
    return const [];
  }

  final currentServer = ref.watch(currentServerProvider);
  if (currentServer == null || currentServer.sourceKind != SourceKind.emby) {
    return [];
  }
  final api = ref.watch(apiClientProvider);
  final results = await api.search.search(query);

  return _filterTopLevelSearchResults(results, hiddenLibraries);
});

List<MediaItem> _filterTopLevelSearchResults(
    Iterable<MediaItem> items, Set<String> hiddenLibraries) {
  final seen = <String>{};
  return items.where((item) {
    if (item.type != 'Movie' && item.type != 'Series') return false;
    if (item.parentId != null &&
        hiddenLibraries.contains(item.parentId.toString())) {
      return false;
    }
    final key = '${item.type}:${item.id}';
    return seen.add(key);
  }).toList();
}

/// 搜索历史
final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
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
final playbackInfoProvider = FutureProvider.autoDispose
    .family<PlaybackInfo, String>((ref, itemId) async {
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
