import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../api/discover/discover_models.dart';
import '../api/discover/discover_service.dart';
import 'app_preferences.dart';

final discoverServiceProvider = Provider<DiscoverService>((ref) {
  return DiscoverService();
});

final reviewSourceProvider =
    StateNotifierProvider<PreferenceNotifier<ReviewSource>, ReviewSource>(
        (ref) {
  return PreferenceNotifier<ReviewSource>(
    defaultValue: ReviewSource.douban,
    readValue: (prefs) =>
        reviewSourceFromWire(prefs.getString('wjplayer_review_source')),
    writeValue: (prefs, value) async {
      await prefs.setString('wjplayer_review_source', value.wireName);
    },
  );
});

final discoverMediaTypeProvider = StateProvider<String>((ref) => 'movie');

final discoverCategoryProvider = StateNotifierProvider.autoDispose.family<
    DiscoverCategoryNotifier,
    AsyncValue<List<DiscoverEntry>>,
    DiscoverCategory>((ref, category) {
  // 与影视来源绑定：切换豆瓣/TMDB/IMDb 时，已打开的分类页也会按新来源重建数据。
  final source = ref.watch(reviewSourceProvider);
  return DiscoverCategoryNotifier(
    service: ref.read(discoverServiceProvider),
    source: source,
    category: category,
  );
});

class DiscoverCategoryNotifier
    extends StateNotifier<AsyncValue<List<DiscoverEntry>>> {
  DiscoverCategoryNotifier({required this.service, required this.source, required this.category})
      : super(const AsyncValue.loading()) {
    loadMore();
  }
  final DiscoverService service;
  final ReviewSource source;
  final DiscoverCategory category;
  final List<DiscoverEntry> _items = [];
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;

  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    try {
      final result = await service.fetchCategoryPage(source, category, _page);
      final seen = _items.map((e) => e.id).toSet();
      _items.addAll(result.entries.where((e) => seen.add(e.id)));
      _page++;
      _hasMore = result.hasMore;
      state = AsyncValue.data(List<DiscoverEntry>.unmodifiable(_items));
    } catch (e, st) {
      if (_items.isEmpty) state = AsyncValue.error(e, st);
    } finally {
      _loading = false;
    }
  }

  Future<void> reload() async {
    _items.clear();
    _page = 0;
    _hasMore = true;
    state = const AsyncValue.loading();
    await loadMore();
  }

  void sort(DiscoverSortPref pref) {
    final sorted = List<DiscoverEntry>.from(_items);
    if (pref.sortBy == 'create_time') {
      if (pref.descending) {
        sorted
          ..clear()
          ..addAll(List<DiscoverEntry>.from(_items.reversed));
      }
      state = AsyncValue.data(sorted);
      return;
    }
    int compare(DiscoverEntry a, DiscoverEntry b) => switch (pref.sortBy) {
          // 评分：同源已有评分，只做本列表降序/升序；无评分沉底
          'rating' => (b.rating ?? -1).compareTo(a.rating ?? -1),
          // 标题：仅当正向时为 A-Z 字母序；倒置时为 Z-A
          'title' => a.title.compareTo(b.title),
          // 出品年份=首映时间；优先用年份，空年份沉底
          'year' => (a.year ?? '').compareTo(b.year ?? ''),
          // 已处理，兜底
          'create_time' => 0,
          _ => 0,
        };
    sorted.sort((a, b) {
      final value = compare(a, b);
      return pref.descending ? -value : value;
    });
    state = AsyncValue.data(sorted);
  }
}

class DiscoverSortPref {
  const DiscoverSortPref({this.sortBy = 'create_time', this.descending = false});
  final String sortBy;
  final bool descending;
}

const kDiscoverSortOptions = <({String label, String key})>[
  (label: '入库时间', key: 'create_time'),
  (label: '标题排序', key: 'title'),
  (label: '首映时间', key: 'year'),
  (label: '评分', key: 'rating'),
];

final discoverEntriesProvider =
    FutureProvider<List<DiscoverEntry>>((ref) async {
  final source = ref.watch(reviewSourceProvider);
  final type = ref.watch(discoverMediaTypeProvider);
  return ref.watch(discoverServiceProvider).fetch(source, mediaType: type);
});

/// 当前来源所有原生榜单并行加载；缓存命中时直接本地返回，单个榜单失败隔离为空。
final discoverSectionsProvider = FutureProvider<
    List<({DiscoverCategory category, List<DiscoverEntry> entries})>>((ref) async {
  final source = ref.watch(reviewSourceProvider);
  final service = ref.watch(discoverServiceProvider);
  final categories = discoverCategoriesFor(source);
  return Future.wait(categories.map((category) async {
    try {
      final entries = await service.fetchCategory(source, category);
      return (category: category, entries: entries);
    } catch (_) {
      return (category: category, entries: const <DiscoverEntry>[]);
    }
  }));
});

final externalRatingProvider = FutureProvider.autoDispose
    .family<double?, ({ReviewSource source, MediaItem item})>(
        (ref, args) async {
  return ref.watch(discoverServiceProvider).ratingFor(args.source, args.item);
});

final selectedExternalRatingProvider =
    FutureProvider.autoDispose.family<double?, MediaItem>((ref, item) async {
  final source = ref.watch(reviewSourceProvider);
  return ref.watch(discoverServiceProvider).ratingFor(source, item);
});
