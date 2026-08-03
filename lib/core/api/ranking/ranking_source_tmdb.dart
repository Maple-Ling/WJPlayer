import 'package:dio/dio.dart';

import '../../services/tmdb_crypto.dart';
import '../../sources/source_http.dart';
import 'ranking_models.dart';

/// TMDB 影视榜数据源（电影 / 剧集）。
///
/// 密钥来自编译期 `--dart-define=TMDB_API_KEY_ENC`（AES 密文），运行时解密。
/// 兼容两种密钥：v4 读取令牌（含 `.` 的 JWT，走 `Authorization: Bearer`）与
/// v3 api_key（走 `?api_key=` 查询参数）。图片走 image.tmdb.org。
class TmdbRankingSource {
  static const String _base = 'https://api.themoviedb.org/3';
  static const String _imgBase = 'https://image.tmdb.org/t/p/w342';

  /// 编译期注入的 AES 密文（非空即视为“已配置”）。
  static const String _enc =
      String.fromEnvironment('TMDB_API_KEY_ENC', defaultValue: '');

  Dio? _dio;
  String _key = '';
  bool _resolved = false;

  /// 构建时是否带了密文（决定 UI 是否展示影视榜分类）。
  bool get isConfigured => _enc.trim().isNotEmpty;

  Future<Dio?> _ensureDio() async {
    if (_resolved) return _dio;
    _resolved = true;
    _key = await TmdbCrypto.decrypt(_enc);
    if (_key.isEmpty) return null;
    final useBearer = _key.contains('.'); // v4 JWT 含点，v3 为 32 位十六进制
    _dio = buildSourceDio(
      baseUrl: _base,
      headers: {
        'Accept': 'application/json',
        if (useBearer) 'Authorization': 'Bearer $_key',
      },
    );
    return _dio;
  }

  Future<List<RankingEntry>> fetch(RankingCategory category) async {
    final path = category.tmdbPath;
    if (path == null || !isConfigured) return const [];
    final dio = await _ensureDio();
    if (dio == null) return const [];
    final useApiKeyQuery = !_key.contains('.');
    final mediaType = path.contains('/tv') ? 'tv' : 'movie';
    try {
      final resp = await dio.get(path, queryParameters: {
        'language': 'zh-CN',
        'page': 1,
        if (useApiKeyQuery) 'api_key': _key,
      });
      final data = resp.data;
      if (data is! Map) return const [];
      final list = data['results'];
      if (list is! List) return const [];
      final entries = <RankingEntry>[];
      var rank = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final title =
            (m['title'] ?? m['name'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        rank++;
        final poster = (m['poster_path'] as String?)?.trim();
        final date =
            (m['release_date'] ?? m['first_air_date'] ?? '').toString();
        final year = date.length >= 4 ? date.substring(0, 4) : null;
        entries.add(RankingEntry(
          source: RankingSource.tmdb,
          id: (m['id'] ?? '').toString(),
          title: title,
          rank: rank,
          imageUrl: (poster == null || poster.isEmpty) ? null : '$_imgBase$poster',
          rating: (m['vote_average'] as num?)?.toDouble(),
          subtitle: year,
          mediaType: mediaType,
        ));
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }
}
