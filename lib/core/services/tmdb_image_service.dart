import 'package:dio/dio.dart';

import '../sources/source_http.dart';
import 'tmdb_crypto.dart';

/// 按 TMDB 剧集 id 取封面（供追剧日历给 Trakt 条目补图）。
///
/// 复用影视榜同一套编译期 AES 密钥（`TMDB_API_KEY_ENC`）。结果按 id 内存缓存，
/// 去重 + 限并发,避免整季视图打爆 TMDB。未配置密钥则静默返回空。
///
/// ponytail: 内存缓存随会话存活即可，封面不值得落盘；缓存 null 表示「查过没有图」，
///           避免同一 id 反复请求。
class TmdbImageService {
  static final TmdbImageService instance = TmdbImageService._();
  TmdbImageService._();

  static const String _base = 'https://api.themoviedb.org/3';
  static const String _imgBase = 'https://image.tmdb.org/t/p/w342';
  static const String _enc =
      String.fromEnvironment('TMDB_API_KEY_ENC', defaultValue: '');
  static const int _concurrency = 6;

  Dio? _dio;
  String _key = '';
  bool _resolved = false;
  final Map<int, String?> _cache = {};

  bool get isConfigured => _enc.trim().isNotEmpty;

  Future<Dio?> _ensureDio() async {
    if (_resolved) return _dio;
    _resolved = true;
    _key = await TmdbCrypto.decrypt(_enc);
    if (_key.isEmpty) return null;
    final useBearer = _key.contains('.');
    _dio = buildSourceDio(
      baseUrl: _base,
      headers: {
        'Accept': 'application/json',
        if (useBearer) 'Authorization': 'Bearer $_key',
      },
    );
    return _dio;
  }

  /// 返回 id → 封面 URL（无图为 null）。
  Future<Map<int, String?>> posters(Set<int> ids) async {
    if (!isConfigured || ids.isEmpty) return const {};
    final dio = await _ensureDio();
    if (dio == null) return const {};
    final useApiKeyQuery = !_key.contains('.');
    final need = ids.where((id) => !_cache.containsKey(id)).toList();
    for (var i = 0; i < need.length; i += _concurrency) {
      final batch = need.skip(i).take(_concurrency);
      await Future.wait(batch.map((id) async {
        try {
          final resp = await dio.get('/tv/$id', queryParameters: {
            'language': 'zh-CN',
            if (useApiKeyQuery) 'api_key': _key,
          });
          final p = resp.data is Map
              ? (resp.data['poster_path'] as String?)?.trim()
              : null;
          _cache[id] = (p == null || p.isEmpty) ? null : '$_imgBase$p';
        } catch (_) {
          _cache[id] = null;
        }
      }));
    }
    return {for (final id in ids) id: _cache[id]};
  }
}
