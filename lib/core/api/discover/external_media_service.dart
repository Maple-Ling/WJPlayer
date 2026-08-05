import 'package:dio/dio.dart';

import '../../services/persistent_json_cache.dart';
import '../../services/tmdb_crypto.dart';
import '../../sources/source_http.dart';
import 'discover_models.dart';
import 'external_media_models.dart';

class ExternalMediaService {
  static const _base = 'https://api.themoviedb.org/3';
  static const _image = 'https://image.tmdb.org/t/p';
  static const _encryptedKey = String.fromEnvironment('TMDB_API_KEY_ENC', defaultValue: '');
  final Dio _douban = buildSourceDio(
    baseUrl: 'https://m.douban.com/rexxar/api/v2',
    headers: const {
      'Accept': 'application/json',
      'Referer': 'https://m.douban.com/',
    },
  );
  final Dio _imdb = buildSourceDio(baseUrl: 'https://v3-cinemeta.strem.io');
  final Dio _imdbGraphql = buildSourceDio(
    baseUrl: 'https://api.graphql.imdb.com',
    headers: const {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Origin': 'https://www.imdb.com',
      'Referer': 'https://www.imdb.com/',
    },
  );

  Future<Dio> _client() async {
    if (_dioCache != null) return _dioCache!;
    final key = await TmdbCrypto.decrypt(_encryptedKey);
    if (key.isEmpty) throw StateError('TMDB API 未配置');
    _tmdbKey = key;
    final bearer = key.contains('.');
    return _dioCache = buildSourceDio(baseUrl: _base, headers: {
      'Accept': 'application/json',
      if (bearer) 'Authorization': 'Bearer $key',
    });
  }

  Dio? _dioCache;
  String _tmdbKey = '';

  Map<String, dynamic> _query([Map<String, dynamic>? extra]) => {
        'language': 'zh-CN',
        if (_tmdbKey.isNotEmpty && !_tmdbKey.contains('.'))
          'api_key': _tmdbKey,
        ...?extra,
      };

  String? _imageUrl(dynamic path, String size) {
    final value = path?.toString();
    return value == null || value.isEmpty ? null : '$_image/$size$value';
  }

  Future<({int id, String type})> resolve(DiscoverEntry entry) async {
    final direct = int.tryParse(entry.tmdbId ?? (entry.source == ReviewSource.tmdb ? entry.id : ''));
    if (direct != null) return (id: direct, type: entry.mediaType == 'tv' ? 'tv' : 'movie');
    final cacheKey = 'tmdb-resolve:${entry.source.name}:${entry.id}:${entry.title}:${entry.year}';
    return PersistentJsonCache.networkFirst(
      key: cacheKey,
      load: () async {
        final dio = await _client();
        if (entry.imdbId?.isNotEmpty == true || entry.source == ReviewSource.imdb) {
          final imdb = entry.imdbId ?? entry.id;
          final response = await dio.get('/find/$imdb', queryParameters: _query({'external_source': 'imdb_id'}));
          final data = response.data as Map;
          final rows = entry.mediaType == 'tv' ? data['tv_results'] : data['movie_results'];
          if (rows is List && rows.isNotEmpty) {
            return (id: (rows.first['id'] as num).toInt(), type: entry.mediaType == 'tv' ? 'tv' : 'movie');
          }
        }
        final response = await dio.get('/search/multi', queryParameters: _query({
          'query': entry.originalTitle?.isNotEmpty == true ? entry.originalTitle : entry.title,
          if (entry.year?.isNotEmpty == true) 'year': entry.year,
          'include_adult': false,
        }));
        final results = (response.data as Map)['results'] as List? ?? const [];
        final wanted = entry.mediaType == 'tv' ? 'tv' : 'movie';
        final row = results.whereType<Map>().firstWhere(
          (item) => item['media_type'] == wanted,
          orElse: () => results.whereType<Map>().first,
        );
        return (id: (row['id'] as num).toInt(), type: '${row['media_type'] ?? wanted}');
      },
      encode: (value) => {'id': value.id, 'type': value.type},
      decode: (value) {
        final map = (value as Map).cast<String, dynamic>();
        return (id: (map['id'] as num).toInt(), type: '${map['type']}');
      },
    );
  }

  Future<ExternalMediaDetail> detail(
    DiscoverEntry entry, {
    ReviewSource? source,
  }) async {
    final selected = source ?? entry.source;
    switch (selected) {
      case ReviewSource.douban:
        return _loadDoubanDetail(entry);
      case ReviewSource.imdb:
        return _loadImdbDetail(entry);
      case ReviewSource.tmdb:
        return _loadTmdbDetail(entry);
    }
  }

  Future<ExternalMediaDetail> _loadTmdbDetail(DiscoverEntry entry) async {
    final resolved = await resolve(entry);
    final key = 'external-detail:tmdb:${resolved.type}:${resolved.id}';
    return PersistentJsonCache.networkFirst(
      key: key,
      load: () => _loadDetail(resolved.id, resolved.type, entry),
      encode: (value) => value.toJson(),
      decode: (value) => ExternalMediaDetail.fromJson(
          (value as Map).cast<String, dynamic>()),
    );
  }

  Future<ExternalMediaDetail> _loadDoubanDetail(DiscoverEntry entry) async {
    final id = entry.doubanId ?? entry.id;
    final response = await _douban.get('/subject/$id');
    final data = (response.data as Map).cast<String, dynamic>();
    final rating = data['rating'];
    final ratingValue = rating is Map ? (rating['value'] as num?)?.toDouble() : null;
    final cover = data['cover_url']?.toString() ??
        (data['pic'] as Map?)?['large']?.toString() ??
        entry.posterUrl;
    final photosFuture = _loadDoubanPhotos(id);
    final recommendationsFuture =
        _loadDoubanRecommendations(id, entry.mediaType);
    final creditsFuture = _loadDoubanCredits(id);
    final results = await Future.wait<dynamic>([
      photosFuture,
      recommendationsFuture,
      creditsFuture,
    ]);
    final photos = results[0] as List<String>;
    final recommendations = results[1] as List<DiscoverEntry>;
    final credits = results[2] as List<ExternalPerson>;
    final actors = credits.isNotEmpty
        ? credits
        : (data['actors'] as List? ?? const [])
            .map(_doubanPerson)
            .whereType<ExternalPerson>()
            .toList();
    final runtime = _parseRuntime(
      (data['durations'] as List?)?.firstOrNull ?? data['duration'],
    );
    return ExternalMediaDetail(
      tmdbId: 0,
      mediaType: entry.mediaType,
      title: '${data['title'] ?? entry.title}',
      originalTitle: data['original_title']?.toString() ?? entry.originalTitle,
      overview: data['intro']?.toString() ??
          data['summary']?.toString() ??
          entry.overview,
      posterUrl: cover,
      backdropUrl: photos.firstOrNull ?? entry.backdropUrl,
      rating: ratingValue ?? entry.rating,
      year: data['year']?.toString() ?? entry.year,
      runtime: runtime,
      genres: (data['genres'] as List? ?? const [])
          .map((item) => '$item')
          .toList(),
      people: actors,
      images: photos,
      recommendations: recommendations,
      doubanId: id,
    );
  }

  Future<List<String>> _loadDoubanPhotos(String id) async {
    try {
      final response = await _douban.get(
        '/subject/$id/photos',
        queryParameters: const {'count': 100},
      );
      final data = response.data;
      if (data is! Map) return const [];
      final rows = data['photos'];
      if (rows is! List) return const [];
      return rows.whereType<Map>().map((photo) {
        final raw = photo.cast<String, dynamic>();
        final image = raw['image'];
        if (image is Map) {
          final imageMap = image.cast<String, dynamic>();
          final large = imageMap['large'];
          final normal = imageMap['normal'];
          if (large is Map && large['url'] != null) {
            return large['url']?.toString();
          }
          if (normal is Map && normal['url'] != null) {
            return normal['url']?.toString();
          }
        }
        return raw['image'] is String
            ? raw['image']?.toString()
            : raw['thumb']?.toString() ?? raw['cover']?.toString();
      }).whereType<String>().where((url) => url.isNotEmpty).toList();
    } catch (_) {
      // 剧照接口失败不影响主详情页。
      return const [];
    }
  }

  Future<List<ExternalPerson>> _loadDoubanCredits(String id) async {
    try {
      final response = await _douban.get('/subject/$id/credits');
      final data = response.data;
      final rows = data is Map ? data['items'] : null;
      if (rows is! List) return const [];
      final seen = <String>{};
      return rows.whereType<Map>().map((raw) {
        final row = raw.cast<String, dynamic>();
        final category = row['category']?.toString();
        if (category != '演员' && category != '导演') return null;
        final avatar = row['avatar'];
        return ExternalPerson(
          id: '${row['id'] ?? ''}',
          name: '${row['name'] ?? ''}',
          source: ReviewSource.douban,
          originalName: row['latin_name']?.toString(),
          character: row['simple_character']?.toString() ?? category,
          profileUrl: avatar is Map
              ? (avatar['large'] ?? avatar['normal'])?.toString()
              : null,
        );
      }).whereType<ExternalPerson>().where((person) =>
          person.name.isNotEmpty && seen.add('${person.id}:${person.character}')).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<DiscoverEntry>> _loadDoubanRecommendations(
      String id, String mediaType) async {
    try {
      final response = await _douban.get('/subject/$id/recommendations');
      final rows = response.data;
      if (rows is! List) return const [];
      return rows.whereType<Map>().map((raw) {
        final row = raw.cast<String, dynamic>();
        final rating = row['rating'];
        final pic = row['pic'];
        final cover = row['cover'];
        final type = '${row['type'] ?? mediaType}';
        return DiscoverEntry(
          id: '${row['id'] ?? ''}',
          title: '${row['title'] ?? ''}',
          originalTitle: row['original_title']?.toString(),
          source: ReviewSource.douban,
          posterUrl: row['cover_url']?.toString() ??
              (pic is Map ? (pic['large'] ?? pic['normal'])?.toString() : null) ??
              (cover is Map ? cover['url']?.toString() : null),
          rating: rating is Map
              ? (rating['value'] as num?)?.toDouble()
              : (rating as num?)?.toDouble(),
          year: row['year']?.toString(),
          overview: row['card_subtitle']?.toString(),
          mediaType: type == 'tv' ? 'tv' : mediaType,
          doubanId: row['id']?.toString(),
        );
      }).where((item) => item.id.isNotEmpty && item.title.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  ExternalPerson? _doubanPerson(dynamic raw) {
    final name = raw is Map ? raw['name']?.toString() : raw?.toString();
    if (name == null || name.isEmpty) return null;
    final map = raw is Map ? raw : const {};
    final avatar = map['avatar'];
    return ExternalPerson(
      id: '${map['id'] ?? ''}',
      name: name,
      source: ReviewSource.douban,
      originalName: map['latin_name']?.toString(),
      profileUrl: map['cover_url']?.toString() ??
          (avatar is Map ? avatar['large']?.toString() : null),
    );
  }

  int? _parseRuntime(dynamic raw) {
    final match = RegExp(r'(\d+)').firstMatch('${raw ?? ''}');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Future<ExternalMediaDetail> _loadImdbDetail(DiscoverEntry entry) async {
    final id = entry.imdbId ?? entry.id;
    final type = entry.mediaType.toLowerCase() == 'movie' ? 'movie' : 'series';
    final response = await _imdb.get('/meta/$type/$id.json');
    final root = (response.data as Map).cast<String, dynamic>();
    final data = (root['meta'] as Map?)?.cast<String, dynamic>() ?? root;
    final castFallback = data['cast'] as List? ?? const [];
    final imdbId = data['imdb_id']?.toString() ?? id;
    final imdbCredits = await _loadImdbCredits(imdbId);
    final seasons = _mapImdbSeasons(data['videos']);
    final people = imdbCredits.isNotEmpty
        ? imdbCredits
        : castFallback.map((item) {
            if (item is Map) {
              return ExternalPerson(
                id: '${item['id'] ?? ''}',
                name: '${item['name'] ?? ''}',
                source: ReviewSource.imdb,
                character: item['character']?.toString(),
                profileUrl: item['photo']?.toString(),
              );
            }
            return ExternalPerson(
              id: '',
              name: '$item',
              source: ReviewSource.imdb,
            );
          }).where((person) => person.name.isNotEmpty).toList();
    return ExternalMediaDetail(
      tmdbId: int.tryParse('${data['moviedb_id'] ?? ''}') ?? 0,
      mediaType: entry.mediaType,
      title: '${data['name'] ?? entry.title}',
      originalTitle: data['original_name']?.toString() ?? entry.originalTitle,
      overview: data['description']?.toString() ?? entry.overview,
      posterUrl: data['poster']?.toString() ?? entry.posterUrl,
      backdropUrl: data['background']?.toString() ?? entry.backdropUrl,
      logoUrl: data['logo']?.toString(),
      rating: double.tryParse('${data['imdbRating'] ?? ''}') ?? entry.rating,
      year: data['year']?.toString() ?? entry.year,
      runtime: _parseRuntime(data['runtime']),
      genres: (data['genres'] as List? ?? data['genre'] as List? ?? const [])
          .map((item) => '$item')
          .toList(),
      people: people,
      imdbId: imdbId,
    );
  }

  /// 将 IMDb 视频列表映射成 ExternalSeason + ExternalEpisode。
  List<ExternalSeason> _mapImdbSeasons(dynamic videos) {
    if (videos is! List) return const [];
    final groups = <int, List<dynamic>>{};
    for (final v in videos) {
      if (v is! Map) continue;
      final season = v['season'];
      final episode = v['episode'];
      if (season is! int || episode is! int) continue;
      groups.putIfAbsent(season, () => []).add(v);
    }
    if (groups.isEmpty) return const [];

    return groups.entries
        .map((e) => ExternalSeason(
              id: e.key,
              number: e.key,
              name: 'Season ${e.key}',
              episodes: e.value
                  .map((v) {
                    final ep = v['episode'];
                    final name = v['name'];
                    final overview = v['overview'];
                    final released = v['released'];
                    final thumb = v['thumbnail'];
                    if (ep is! int) return null;
                    return ExternalEpisode(
                      id: ep,
                      number: ep,
                      name: name?.toString() ?? '',
                      overview: overview?.toString(),
                      airDate: released?.toString(),
                      stillUrl: thumb?.toString(),
                    );
                  })
                  .whereType<ExternalEpisode>()
                  .toList(),
            ))
        .toList();
  }

  Future<List<ExternalPerson>> _loadImdbCredits(String id) async {
    const query = r'''
      query WJPlayerTitleCredits($id: ID!) {
        title(id: $id) {
          credits(first: 30, filter: {categories: ["cast"]}) {
            edges {
              node {
                name {
                  id
                  nameText { text }
                  primaryImage { url }
                }
                ... on Cast { characters { name } }
              }
            }
          }
        }
      }
    ''';
    try {
      final response = await _imdbGraphql.post<dynamic>(
        '/',
        data: {'query': query, 'variables': {'id': id}},
      );
      final root = response.data;
      if (root is! Map) return const [];
      final data = root['data'];
      final title = data is Map ? data['title'] : null;
      final credits = title is Map ? title['credits'] : null;
      final edges = credits is Map ? credits['edges'] : null;
      if (edges is! List) return const [];
      return edges.whereType<Map>().map((edge) {
        final node = edge['node'];
        if (node is! Map) return null;
        final name = node['name'];
        if (name is! Map) return null;
        final nameText = name['nameText'];
        final image = name['primaryImage'];
        final characters = node['characters'];
        return ExternalPerson(
          id: '${name['id'] ?? ''}',
          name: nameText is Map ? '${nameText['text'] ?? ''}' : '',
          source: ReviewSource.imdb,
          character: characters is List
              ? characters
                  .whereType<Map>()
                  .map((item) => '${item['name'] ?? ''}')
                  .where((value) => value.isNotEmpty)
                  .join(' / ')
              : null,
          profileUrl: image is Map ? image['url']?.toString() : null,
        );
      }).whereType<ExternalPerson>().where((person) => person.name.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<ExternalMediaDetail> _loadDetail(int id, String type, DiscoverEntry original) async {
    final dio = await _client();
    final response = await dio.get('/$type/$id', queryParameters: _query({
      'append_to_response': 'credits,images,recommendations,external_ids',
      'include_image_language': 'zh,en,null',
    }));
    final data = (response.data as Map).cast<String, dynamic>();
    final credits = data['credits'] as Map? ?? const {};
    final images = data['images'] as Map? ?? const {};
    final recommendations = data['recommendations'] as Map? ?? const {};
    final external = data['external_ids'] as Map? ?? const {};
    final date = '${data['release_date'] ?? data['first_air_date'] ?? ''}';
    final recs = (recommendations['results'] as List? ?? const []).whereType<Map>().take(20).map((raw) {
      final row = raw.cast<String, dynamic>();
      final mediaType = '${row['media_type'] ?? type}';
      final release = '${row['release_date'] ?? row['first_air_date'] ?? ''}';
      return DiscoverEntry(
        id: '${row['id']}',
        title: '${row['title'] ?? row['name'] ?? ''}',
        originalTitle: (row['original_title'] ?? row['original_name'])?.toString(),
        source: ReviewSource.tmdb,
        posterUrl: _imageUrl(row['poster_path'], 'w500'),
        backdropUrl: _imageUrl(row['backdrop_path'], 'w1280'),
        rating: (row['vote_average'] as num?)?.toDouble(),
        year: release.length >= 4 ? release.substring(0, 4) : null,
        overview: row['overview']?.toString(),
        mediaType: mediaType,
        tmdbId: '${row['id']}',
      );
    }).toList();
    return ExternalMediaDetail(
      tmdbId: id,
      mediaType: type,
      title: '${data['title'] ?? data['name'] ?? original.title}',
      originalTitle: (data['original_title'] ?? data['original_name'])?.toString(),
      overview: (data['overview']?.toString().isNotEmpty == true ? data['overview'] : original.overview)?.toString(),
      posterUrl: _imageUrl(data['poster_path'], 'w780') ?? original.posterUrl,
      backdropUrl: _imageUrl(data['backdrop_path'], 'original') ?? original.backdropUrl,
      logoUrl: (images['logos'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => _imageUrl(row['file_path'], 'w500'))
          .whereType<String>()
          .firstOrNull,
      rating: (data['vote_average'] as num?)?.toDouble() ?? original.rating,
      year: date.length >= 4 ? date.substring(0, 4) : original.year,
      status: data['status']?.toString(),
      runtime: (data['runtime'] as num?)?.toInt() ??
          ((data['episode_run_time'] as List?)?.isNotEmpty == true
              ? ((data['episode_run_time'] as List).first as num?)?.toInt()
              : null),
      numberOfSeasons: (data['number_of_seasons'] as num?)?.toInt(),
      genres: (data['genres'] as List? ?? const []).whereType<Map>().map((e) => '${e['name']}').toList(),
      seasons: (data['seasons'] as List? ?? const []).whereType<Map>().map((row) => ExternalSeason(
        id: (row['id'] as num?)?.toInt() ?? 0,
        number: (row['season_number'] as num?)?.toInt() ?? 0,
        name: '${row['name'] ?? ''}',
        posterUrl: _imageUrl(row['poster_path'], 'w500'),
        episodeCount: (row['episode_count'] as num?)?.toInt() ?? 0,
      )).toList(),
      people: (credits['cast'] as List? ?? const []).whereType<Map>().take(30).map((row) => ExternalPerson(
        id: '${row['id'] ?? ''}',
        name: '${row['name'] ?? ''}',
        source: ReviewSource.tmdb,
        originalName: row['original_name']?.toString(),
        character: row['character']?.toString(),
        profileUrl: _imageUrl(row['profile_path'], 'w500'),
      )).toList(),
      images: (images['backdrops'] as List? ?? const []).whereType<Map>().map((row) => _imageUrl(row['file_path'], 'original')).whereType<String>().take(40).toList(),
      recommendations: recs,
      companies: [
        ...(data['production_companies'] as List? ?? const []),
        ...(data['networks'] as List? ?? const []),
      ].whereType<Map>().map((row) => ExternalCompany(
        id: (row['id'] as num?)?.toInt() ?? 0,
        name: '${row['name'] ?? ''}',
        logoUrl: _imageUrl(row['logo_path'], 'w300'),
      )).toList(),
      imdbId: external['imdb_id']?.toString() ?? original.imdbId,
      doubanId: original.doubanId,
    );
  }

  Future<ExternalSeason> season(int tmdbId, int number) => PersistentJsonCache.networkFirst(
        key: 'external-season:$tmdbId:$number',
        load: () async {
          final dio = await _client();
          final response = await dio.get('/tv/$tmdbId/season/$number', queryParameters: _query());
          final data = (response.data as Map).cast<String, dynamic>();
          return ExternalSeason(
            id: (data['id'] as num?)?.toInt() ?? 0,
            number: number,
            name: '${data['name'] ?? '第 $number 季'}',
            posterUrl: _imageUrl(data['poster_path'], 'w500'),
            episodeCount: (data['episodes'] as List?)?.length ?? 0,
            episodes: (data['episodes'] as List? ?? const []).whereType<Map>().map((row) => ExternalEpisode(
              id: (row['id'] as num?)?.toInt() ?? 0,
              number: (row['episode_number'] as num?)?.toInt() ?? 0,
              name: '${row['name'] ?? ''}',
              overview: row['overview']?.toString(),
              stillUrl: _imageUrl(row['still_path'], 'w780'),
              airDate: row['air_date']?.toString(),
              runtime: (row['runtime'] as num?)?.toInt(),
            )).toList(),
          );
        },
        encode: (value) => value.toJson(),
        decode: (value) => ExternalSeason.fromJson((value as Map).cast<String, dynamic>()),
      );

  Future<List<DiscoverEntry>> personCredits(ExternalPerson person) {
    if (person.source == ReviewSource.douban) {
      return _doubanPersonWorks(person);
    }
    if (person.source == ReviewSource.imdb) {
      return _imdbPersonWorks(person);
    }
    return _tmdbPersonWorks(person);
  }

  Future<List<DiscoverEntry>> _doubanPersonWorks(ExternalPerson person) =>
      PersistentJsonCache.networkFirst(
        key: 'douban-person-works:${person.id}',
        load: () async {
          final response = await _douban.get('/celebrity/${person.id}/works');
          final data = response.data;
          final rows = data is Map ? data['works'] : null;
          if (rows is! List) return const [];
          final seen = <String>{};
          return rows.whereType<Map>().map((raw) {
            final row = raw.cast<String, dynamic>();
            final work = row['work'];
            final detail = work is Map ? work.cast<String, dynamic>() : const <String, dynamic>{};
            final id = '${detail['id'] ?? ''}';
            if (id.isEmpty || !seen.add(id)) return null;
            final rating = detail['rating'];
            final pic = detail['pic'];
            return DiscoverEntry(
              id: id,
              title: '${detail['title'] ?? ''}',
              originalTitle: detail['original_title']?.toString(),
              source: ReviewSource.douban,
              posterUrl: detail['cover_url']?.toString() ??
                  (pic is Map ? (pic['large'] ?? pic['normal'])?.toString() : null),
              rating: rating is Map
                  ? (rating['value'] as num?)?.toDouble()
                  : (rating as num?)?.toDouble(),
              year: detail['year']?.toString(),
              overview: detail['card_subtitle']?.toString(),
              mediaType: detail['subtype'] == 'tv' ? 'tv' : 'movie',
              doubanId: id,
            );
          }).whereType<DiscoverEntry>().toList();
        },
        encode: (value) => value.map((e) => e.toJson()).toList(),
        decode: (value) => (value as List)
            .whereType<Map>()
            .map((e) => DiscoverEntry.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  Future<List<DiscoverEntry>> _imdbPersonWorks(ExternalPerson person) =>
      PersistentJsonCache.networkFirst(
        key: 'imdb-person-works:${person.id}',
        load: () async {
          const query = r'''
            query WJPlayerNameCredits($id: ID!) {
              name(id: $id) {
                credits(first: 25) {
                  edges {
                    node {
                      title {
                        id
                        titleText { text }
                        primaryImage { url }
                        releaseYear { year }
                        ratingsSummary { aggregateRating }
                        titleType { isSeries }
                      }
                    }
                  }
                }
              }
            }
          ''';
          final response = await _imdbGraphql.post<dynamic>(
            '/',
            data: {'query': query, 'variables': {'id': person.id}},
          );
          final root = response.data;
          if (root is! Map) return const [];
          final data = root['data'];
          final name = data is Map ? data['name'] : null;
          final credits = name is Map ? name['credits'] : null;
          final edges = credits is Map ? credits['edges'] : null;
          if (edges is! List) return const [];
          return edges.whereType<Map>().map((edge) {
            final node = edge['node'];
            final title = node is Map ? node['title'] : null;
            if (title is! Map) return null;
            final titleText = title['titleText'];
            final image = title['primaryImage'];
            final year = title['releaseYear'];
            final rating = title['ratingsSummary'];
            final type = title['titleType'];
            final isSeries = type is Map && type['isSeries'] == true;
            return DiscoverEntry(
              id: '${title['id'] ?? ''}',
              title: titleText is Map ? '${titleText['text'] ?? ''}' : '',
              source: ReviewSource.imdb,
              posterUrl: image is Map ? image['url']?.toString() : null,
              rating: rating is Map
                  ? (rating['aggregateRating'] as num?)?.toDouble()
                  : null,
              year: year is Map ? '${year['year'] ?? ''}' : null,
              mediaType: isSeries ? 'tv' : 'movie',
              imdbId: '${title['id'] ?? ''}',
            );
          }).whereType<DiscoverEntry>().where((item) => item.id.isNotEmpty && item.title.isNotEmpty).toList();
        },
        encode: (value) => value.map((e) => e.toJson()).toList(),
        decode: (value) => (value as List)
            .whereType<Map>()
            .map((e) => DiscoverEntry.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  Future<List<DiscoverEntry>> _tmdbPersonWorks(ExternalPerson person) => PersistentJsonCache.networkFirst(
        key: 'person-credits:${person.id}',
        load: () async {
          final dio = await _client();
          final response = await dio.get('/person/${person.id}/combined_credits', queryParameters: _query());
          return ((response.data as Map)['cast'] as List? ?? const []).whereType<Map>().map((row) {
            final type = '${row['media_type'] ?? 'movie'}';
            final date = '${row['release_date'] ?? row['first_air_date'] ?? ''}';
            return DiscoverEntry(id:'${row['id']}',title:'${row['title'] ?? row['name'] ?? ''}',source:ReviewSource.tmdb,posterUrl:_imageUrl(row['poster_path'],'w500'),backdropUrl:_imageUrl(row['backdrop_path'],'w1280'),rating:(row['vote_average'] as num?)?.toDouble(),year:date.length>=4?date.substring(0,4):null,mediaType:type,tmdbId:'${row['id']}');
          }).where((e)=>e.title.isNotEmpty).toList()..sort((a,b)=>(b.rating??0).compareTo(a.rating??0));
        },
        encode: (value) => value.map((e)=>e.toJson()).toList(),
        decode: (value) => (value as List).whereType<Map>().map((e)=>DiscoverEntry.fromJson(e.cast<String,dynamic>())).toList(),
      );
}
