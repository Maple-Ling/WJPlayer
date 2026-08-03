import 'package:dio/dio.dart';

import '../../services/tmdb_crypto.dart';
import '../../services/persistent_json_cache.dart';
import '../../sources/source_http.dart';
import '../api_interfaces.dart';
import 'discover_models.dart';

class DiscoverService {
  DiscoverService();

  static const _tmdbBase = 'https://api.themoviedb.org/3';
  static const _tmdbImage = 'https://image.tmdb.org/t/p/w500';
  static const _tmdbBackdrop = 'https://image.tmdb.org/t/p/w1280';
  static const _tmdbEnc =
      String.fromEnvironment('TMDB_API_KEY_ENC', defaultValue: '');

  final Dio _douban = buildSourceDio(
    baseUrl: 'https://m.douban.com/rexxar/api/v2',
    headers: const {
      'Accept': 'application/json',
      'Referer': 'https://m.douban.com/',
    },
  );
  final Dio _doubanWeb = buildSourceDio(
    baseUrl: 'https://movie.douban.com',
    headers: const {
      'Accept': 'text/html',
      'Referer': 'https://movie.douban.com/',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36',
    },
  );
  final Dio _imdb = buildSourceDio(baseUrl: 'https://v3-cinemeta.strem.io');
  Dio? _tmdb;
  String _tmdbKey = '';
  bool _tmdbResolved = false;
  final Map<String, double?> _ratingCache = {};

  Future<List<DiscoverEntry>> fetch(
    ReviewSource source, {
    String mediaType = 'movie',
  }) =>
      fetchCategory(
        source,
        discoverCategoriesFor(source)
            .firstWhere((category) => category.mediaType == mediaType),
      );

  Future<List<DiscoverEntry>> fetchCategory(
    ReviewSource source,
    DiscoverCategory category, {
    bool forceRefresh = false,
  }) {
    final key = 'discover:${source.name}:${category.id}';
    final loader = () => PersistentJsonCache.networkFirst<List<DiscoverEntry>>(
          key: key,
          load: () => switch (source) {
            ReviewSource.douban => category.id.startsWith('chart:')
                ? _fetchDoubanChart(category)
                : category.id.startsWith('annual:')
                    ? _fetchDoubanAnnual(category)
                    : _fetchDoubanCollection(category),
            ReviewSource.tmdb => _fetchTmdbPath(category),
            ReviewSource.imdb => _fetchImdbCatalog(category),
          },
          encode: (entries) => entries.map((entry) => entry.toJson()).toList(),
          decode: (value) => (value as List)
              .whereType<Map>()
              .map((item) => DiscoverEntry.fromJson(item.cast<String, dynamic>()))
              .toList(),
        );
    if (forceRefresh) return loader();
    return PersistentJsonCache.cacheFirst(
      key: key,
      load: loader,
      decode: (value) => (value as List)
          .whereType<Map>()
          .map((item) => DiscoverEntry.fromJson(item.cast<String, dynamic>()))
          .toList(),
    );
  }

  Future<({List<DiscoverEntry> entries, bool hasMore})> fetchCategoryPage(
    ReviewSource source,
    DiscoverCategory category,
    int page,
  ) async {
    switch (source) {
      case ReviewSource.douban:
        if (category.id.startsWith('chart:') || category.id.startsWith('annual:')) {
          final entries = await fetchCategory(source, category);
          return (entries: entries, hasMore: false);
        }
        return _fetchDoubanCollectionPage(category, page);
      case ReviewSource.tmdb:
        return _fetchTmdbPathPage(category, page);
      case ReviewSource.imdb:
        return _fetchImdbCatalogPage(category, page);
    }
  }

  Future<({List<DiscoverEntry> entries, bool hasMore})> _fetchDoubanCollectionPage(
      DiscoverCategory category, int page) async {
    const count = 40;
    final filter = category.id.startsWith('filter:');
    final response = filter
        ? await _douban.get('/${category.id.substring(7)}/recommend', queryParameters: {'refresh': 0, 'start': page * count, 'count': count, 'selected_categories': '{}', 'uncollect': false, 'tags': ''})
        : await _douban.get('/subject_collection/${category.id}/items', queryParameters: {'start': page * count, 'count': count, 'items_only': 1, 'for_mobile': 1});
    final data = response.data;
    if (data is! Map) return (entries: <DiscoverEntry>[], hasMore: false);
    final rows = filter ? data['items'] : data['subject_collection_items'];
    if (rows is! List) return (entries: <DiscoverEntry>[], hasMore: false);
    final entries = rows.whereType<Map>().where((raw) => !filter || raw['type'] == category.mediaType).map((raw) {
      final row = raw.cast<String, dynamic>();
      final rating = row['rating'];
      final cover = row['cover'];
      final pic = row['pic'];
      return DiscoverEntry(id: '${row['id'] ?? ''}', title: '${row['title'] ?? ''}', originalTitle: row['original_title']?.toString(), source: ReviewSource.douban, posterUrl: cover is Map ? cover['url']?.toString() : (pic is Map ? (pic['large'] ?? pic['normal'])?.toString() : null), rating: rating is Map ? (rating['value'] as num?)?.toDouble() : null, year: row['year']?.toString(), overview: row['card_subtitle']?.toString(), mediaType: category.mediaType, doubanId: row['id']?.toString());
    }).where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty).toList();
    return (entries: entries, hasMore: entries.length == count);
  }

  Future<({List<DiscoverEntry> entries, bool hasMore})> _fetchTmdbPathPage(DiscoverCategory category, int page) async {
    final dio = await _ensureTmdb();
    if (dio == null) return (entries: <DiscoverEntry>[], hasMore: false);
    final uri = Uri.parse(category.id);
    final response = await dio.get(uri.path, queryParameters: {...uri.queryParameters, 'language': 'zh-CN', 'page': page + 1, if (!_tmdbKey.contains('.')) 'api_key': _tmdbKey});
    final data = response.data;
    if (data is! Map || data['results'] is! List) return (entries: <DiscoverEntry>[], hasMore: false);
    final entries = _tmdbEntries(data['results'] as List, category.mediaType);
    final total = (data['total_pages'] as num?)?.toInt() ?? page + 1;
    return (entries: entries, hasMore: page + 1 < total && entries.isNotEmpty);
  }

  Future<({List<DiscoverEntry> entries, bool hasMore})> _fetchImdbCatalogPage(DiscoverCategory category, int page) async {
    final response = await _imdb.get('/catalog/${category.id}/skip=${page * 40}.json');
    final data = response.data;
    if (data is! Map || data['metas'] is! List) return (entries: <DiscoverEntry>[], hasMore: false);
    final entries = _imdbEntries(data['metas'] as List, category.mediaType);
    return (entries: entries, hasMore: entries.length == 40);
  }

  List<DiscoverEntry> _tmdbEntries(List rows, String mediaType) => rows.whereType<Map>().map((raw) {
    final row = raw.cast<String, dynamic>();
    final poster = row['poster_path']?.toString();
    final backdrop = row['backdrop_path']?.toString();
    final date = '${row['release_date'] ?? row['first_air_date'] ?? ''}';
    return DiscoverEntry(id: '${row['id'] ?? ''}', title: '${row['title'] ?? row['name'] ?? ''}', originalTitle: (row['original_title'] ?? row['original_name'])?.toString(), source: ReviewSource.tmdb, posterUrl: poster == null || poster.isEmpty ? null : '$_tmdbImage$poster', backdropUrl: backdrop == null || backdrop.isEmpty ? null : '$_tmdbBackdrop$backdrop', rating: (row['vote_average'] as num?)?.toDouble(), year: date.length >= 4 ? date.substring(0, 4) : null, overview: row['overview']?.toString(), mediaType: mediaType, tmdbId: row['id']?.toString());
  }).where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty).toList();

  List<DiscoverEntry> _imdbEntries(List rows, String mediaType) => rows.whereType<Map>().map((raw) {
    final row = raw.cast<String, dynamic>();
    return DiscoverEntry(id: '${row['id'] ?? row['imdb_id'] ?? ''}', title: '${row['name'] ?? ''}', source: ReviewSource.imdb, posterUrl: row['poster']?.toString(), backdropUrl: row['background']?.toString(), rating: double.tryParse('${row['imdbRating'] ?? ''}'), year: row['year']?.toString(), overview: row['description']?.toString(), mediaType: mediaType, tmdbId: row['moviedb_id']?.toString(), imdbId: (row['imdb_id'] ?? row['id'])?.toString(), genres: (row['genres'] as List?)?.map((e) => '$e').toList() ?? const []);
  }).where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty).toList();

  Future<double?> ratingFor(ReviewSource source, MediaItem item) async {
    final providerId = _providerId(item.providerIds, source.name);
    final id = switch (source) {
      ReviewSource.tmdb => item.tmdbId,
      ReviewSource.imdb => item.imdbId,
      ReviewSource.douban => providerId,
    };
    if (id == null || id.isEmpty) return null;
    final key = '${source.name}:$id:${item.type}';
    if (_ratingCache.containsKey(key)) return _ratingCache[key];
    double? value;
    try {
      value = switch (source) {
        ReviewSource.douban => await _doubanRating(id),
        ReviewSource.tmdb => await _tmdbRating(id, item.type),
        ReviewSource.imdb => await _imdbRating(id, item.type),
      };
    } catch (_) {
      value = null;
    }
    _ratingCache[key] = value;
    return value;
  }

  Future<List<DiscoverEntry>> _fetchDoubanCollection(
      DiscoverCategory category) async {
    final mediaType = category.mediaType;
    final filter = category.id.startsWith('filter:');
    final response = filter
        ? await _douban.get(
            '/${category.id.substring(7)}/recommend',
            queryParameters: const {
              'refresh': 0,
              'start': 0,
              'count': 40,
              'selected_categories': '{}',
              'uncollect': false,
              'tags': '',
            },
          )
        : await _douban.get(
            '/subject_collection/${category.id}/items',
            queryParameters: const {
              'start': 0,
              'count': 40,
              'items_only': 1,
              'for_mobile': 1,
            },
          );
    final data = response.data;
    if (data is! Map) return const [];
    final rows = filter ? data['items'] : data['subject_collection_items'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .where((raw) => !filter || raw['type'] == mediaType)
        .map((raw) {
          final row = raw.cast<String, dynamic>();
          final rating = row['rating'];
          final cover = row['cover'];
          final pic = row['pic'];
          return DiscoverEntry(
            id: '${row['id'] ?? ''}',
            title: '${row['title'] ?? ''}',
            originalTitle: row['original_title']?.toString(),
            source: ReviewSource.douban,
            posterUrl: cover is Map
                ? cover['url']?.toString()
                : (pic is Map ? (pic['large'] ?? pic['normal'])?.toString() : null),
            rating:
                rating is Map ? (rating['value'] as num?)?.toDouble() : null,
            year: row['year']?.toString(),
            overview: row['card_subtitle']?.toString(),
            mediaType: mediaType,
            doubanId: row['id']?.toString(),
          );
        })
        .where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty)
        .toList();
  }

  Future<List<DiscoverEntry>> _fetchDoubanAnnual(DiscoverCategory category) async {
    final year = category.id.substring('annual:'.length);
    final response = await _doubanWeb.get(
      '/j/neu/page/movie_$year/',
      queryParameters: {'source': 'movie_navigation_logo'},
    );
    final data = response.data;
    if (data is! Map || data['widgets'] is! List) return const [];
    final entries = <DiscoverEntry>[];
    final seen = <String>{};
    void collect(dynamic node) {
      if (node is Map) {
        final rows = node['subject_collection_items'];
        if (rows is List) {
          for (final raw in rows.whereType<Map>()) {
            final row = raw.cast<String, dynamic>();
            final id = '${row['id'] ?? ''}';
            if (id.isEmpty || !seen.add(id)) continue;
            final rating = row['rating'];
            entries.add(DiscoverEntry(
              id: id,
              title: '${row['title'] ?? ''}',
              source: ReviewSource.douban,
              posterUrl: (row['cover_url'] ?? row['cover'])?.toString(),
              rating: rating is Map ? (rating['value'] as num?)?.toDouble() : (rating as num?)?.toDouble(),
              year: year,
              overview: row['card_subtitle']?.toString(),
              mediaType: 'movie',
              doubanId: id,
            ));
          }
        }
        for (final value in node.values) collect(value);
      } else if (node is List) {
        for (final value in node) collect(value);
      }
    }
    collect(data['widgets']);
    return entries.where((entry) => entry.title.isNotEmpty).take(60).toList();
  }

  Future<List<DiscoverEntry>> _fetchDoubanChart(DiscoverCategory category) async {
    final response = await _doubanWeb.get<String>('/chart', options: Options(responseType: ResponseType.plain));
    final html = response.data ?? '';
    final segment = category.id == 'chart:us'
        ? (html.contains('北美票房榜') ? html.substring(html.indexOf('北美票房榜')) : '')
        : (html.contains('豆瓣新片榜') ? html.substring(html.indexOf('豆瓣新片榜'), html.indexOf('北美票房榜') > 0 ? html.indexOf('北美票房榜') : html.length) : '');
    if (segment.isEmpty) return const [];
    final pattern = RegExp(
      r'href="https://movie\.douban\.com/subject/(\d+)/[^>]*>[\s\S]*?<img[^>]+src="([^"]+)"[^>]*>[\s\S]*?<a[^>]+class="nbg"[^>]*title="([^"]+)"|href="https://movie\.douban\.com/subject/(\d+)/[^>]*title="([^"]+)"',
      multiLine: true,
    );
    final fallback = RegExp(r'https://movie\.douban\.com/subject/(\d+)/[^" ]*[\s\S]{0,900}?<img[^>]+src="([^"]+)"[^>]*[\s\S]{0,500}?class="pl2"[\s\S]{0,500}?>([^<>]{1,100})</a>', multiLine: true);
    final matches = fallback.allMatches(segment).take(category.id == 'chart:us' ? 20 : 40);
    return matches.map((match) {
      final title = match.group(3)?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      return DiscoverEntry(
        id: match.group(1) ?? '',
        title: title.replaceAll(RegExp(r'\s*/.*$'), '').trim(),
        source: ReviewSource.douban,
        posterUrl: match.group(2),
        mediaType: 'movie',
        doubanId: match.group(1),
      );
    }).where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty).toList();
  }

  Future<List<DiscoverEntry>> _fetchImdbCatalog(
      DiscoverCategory category) async {
    final mediaType = category.mediaType;
    final response = await _imdb.get('/catalog/${category.id}.json');
    final data = response.data;
    if (data is! Map || data['metas'] is! List) return const [];
    return (data['metas'] as List)
        .whereType<Map>()
        .map((raw) {
          final row = raw.cast<String, dynamic>();
          return DiscoverEntry(
            id: '${row['id'] ?? row['imdb_id'] ?? ''}',
            title: '${row['name'] ?? ''}',
            source: ReviewSource.imdb,
            posterUrl: row['poster']?.toString(),
            backdropUrl: row['background']?.toString(),
            rating: double.tryParse('${row['imdbRating'] ?? ''}'),
            year: row['year']?.toString(),
            overview: row['description']?.toString(),
            mediaType: mediaType,
            tmdbId: row['moviedb_id']?.toString(),
            imdbId: (row['imdb_id'] ?? row['id'])?.toString(),
            genres:
                (row['genres'] as List?)?.map((e) => '$e').toList() ?? const [],
          );
        })
        .where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty)
        .take(40)
        .toList();
  }

  Future<List<DiscoverEntry>> _fetchTmdbPath(
      DiscoverCategory category) async {
    final dio = await _ensureTmdb();
    if (dio == null) return const [];
    final mediaType = category.mediaType;
    final uri = Uri.parse(category.id);
    final response = await dio.get(uri.path, queryParameters: {
      ...uri.queryParameters,
      'language': 'zh-CN',
      'page': 1,
      if (!_tmdbKey.contains('.')) 'api_key': _tmdbKey,
    });
    final data = response.data;
    if (data is! Map || data['results'] is! List) return const [];
    return (data['results'] as List)
        .whereType<Map>()
        .map((raw) {
          final row = raw.cast<String, dynamic>();
          final poster = row['poster_path']?.toString();
          final backdrop = row['backdrop_path']?.toString();
          final date = '${row['release_date'] ?? row['first_air_date'] ?? ''}';
          return DiscoverEntry(
            id: '${row['id'] ?? ''}',
            title: '${row['title'] ?? row['name'] ?? ''}',
            originalTitle:
                (row['original_title'] ?? row['original_name'])?.toString(),
            source: ReviewSource.tmdb,
            posterUrl:
                poster == null || poster.isEmpty ? null : '$_tmdbImage$poster',
            backdropUrl: backdrop == null || backdrop.isEmpty
                ? null
                : '$_tmdbBackdrop$backdrop',
            rating: (row['vote_average'] as num?)?.toDouble(),
            year: date.length >= 4 ? date.substring(0, 4) : null,
            overview: row['overview']?.toString(),
            mediaType: mediaType,
            tmdbId: row['id']?.toString(),
          );
        })
        .where((entry) => entry.id.isNotEmpty && entry.title.isNotEmpty)
        .toList();
  }

  Future<Dio?> _ensureTmdb() async {
    if (_tmdbResolved) return _tmdb;
    _tmdbResolved = true;
    _tmdbKey = await TmdbCrypto.decrypt(_tmdbEnc);
    if (_tmdbKey.isEmpty) return null;
    final bearer = _tmdbKey.contains('.');
    _tmdb = buildSourceDio(
      baseUrl: _tmdbBase,
      headers: {
        'Accept': 'application/json',
        if (bearer) 'Authorization': 'Bearer $_tmdbKey',
      },
    );
    return _tmdb;
  }

  Future<double?> _doubanRating(String id) async {
    final response = await _douban.get('/movie/$id');
    final data = response.data;
    final rating = data is Map ? data['rating'] : null;
    return rating is Map ? (rating['value'] as num?)?.toDouble() : null;
  }

  Future<double?> _imdbRating(String id, String itemType) async {
    final type = itemType.toLowerCase() == 'movie' ? 'movie' : 'series';
    final response = await _imdb.get('/meta/$type/$id.json');
    final data = response.data;
    final meta = data is Map ? data['meta'] : null;
    return meta is Map ? double.tryParse('${meta['imdbRating'] ?? ''}') : null;
  }

  Future<double?> _tmdbRating(String id, String itemType) async {
    final dio = await _ensureTmdb();
    if (dio == null) return null;
    final type = itemType.toLowerCase() == 'movie' ? 'movie' : 'tv';
    final response = await dio.get('/$type/$id', queryParameters: {
      'language': 'zh-CN',
      if (!_tmdbKey.contains('.')) 'api_key': _tmdbKey,
    });
    final data = response.data;
    return data is Map ? (data['vote_average'] as num?)?.toDouble() : null;
  }

  String? _providerId(Map<String, String>? ids, String target) {
    if (ids == null) return null;
    for (final entry in ids.entries) {
      if (entry.key.toLowerCase() == target && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }
}
