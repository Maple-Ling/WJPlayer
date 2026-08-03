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
  Dio? _dio;
  String _key = '';

  Future<Dio> _client() async {
    if (_dio != null) return _dio!;
    _key = await TmdbCrypto.decrypt(_encryptedKey);
    if (_key.isEmpty) throw StateError('TMDB API 未配置');
    final bearer = _key.contains('.');
    return _dio = buildSourceDio(baseUrl: _base, headers: {
      'Accept': 'application/json',
      if (bearer) 'Authorization': 'Bearer $_key',
    });
  }

  Map<String, dynamic> _query([Map<String, dynamic>? extra]) => {
        'language': 'zh-CN',
        if (!_key.contains('.')) 'api_key': _key,
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

  Future<ExternalMediaDetail> detail(DiscoverEntry entry) async {
    final resolved = await resolve(entry);
    final key = 'external-detail:${resolved.type}:${resolved.id}';
    final detail = await PersistentJsonCache.networkFirst(
      key: key,
      load: () => _loadDetail(resolved.id, resolved.type, entry),
      encode: (value) => value.toJson(),
      decode: (value) => ExternalMediaDetail.fromJson((value as Map).cast<String, dynamic>()),
    );
    return detail;
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
        id: (row['id'] as num?)?.toInt() ?? 0,
        name: '${row['name'] ?? ''}',
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

  Future<List<DiscoverEntry>> personCredits(ExternalPerson person) => PersistentJsonCache.networkFirst(
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
