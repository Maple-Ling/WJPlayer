import 'package:dio/dio.dart';

import '../../sources/source_http.dart';
import '../danmaku/dandan_signing.dart';
import 'ranking_models.dart';

/// 弹弹Play「排行榜」数据源。
///
/// 官方开放平台端点（均需签名鉴权，凭据编译期注入，与弹幕共用）：
/// - `GET /api/v2/trending/all/hot/{week|month|quarter}`   全站热门
/// - `GET /api/v2/trending/all/rising/{week|month|quarter}` 飙升
/// - `GET /api/v2/trending/new-anime/hot/{current-season|previous-season}` 新番热度
///
/// 返回 `bangumiList[]{ animeId, animeTitle, imageUrl, rating, isFavorited }`。
class DandanRankingSource {
  static const String _baseUrl = 'https://api.dandanplay.net';

  final DandanSigner _signer;
  late final Dio _dio = buildSourceDio(baseUrl: _baseUrl);

  DandanRankingSource({DandanSigner? signer})
      : _signer = signer ?? DandanSigner.fromEnvironment();

  /// 有凭据才参与（开放平台端点无凭据必 401，避免噪音）。
  bool get isConfigured => _signer.hasCredentials;

  Future<List<RankingEntry>> fetch(RankingCategory category) async {
    final seg = category.dandanPath;
    if (seg == null || !isConfigured) return const [];
    final path = '/api/v2/trending/$seg';
    try {
      final resp = await _dio.get(
        path,
        queryParameters: const {'filterAdultContent': true, 'limit': 50},
        options: _signer.authOptions(path),
      );
      final data = resp.data;
      if (data is! Map || data['success'] != true) return const [];
      final list = data['bangumiList'];
      if (list is! List) return const [];
      final entries = <RankingEntry>[];
      var rank = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final title = (m['animeTitle'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        rank++;
        entries.add(RankingEntry(
          source: RankingSource.dandan,
          id: (m['animeId'] ?? '').toString(),
          title: title,
          rank: rank,
          imageUrl: (m['imageUrl'] as String?)?.trim().isEmpty ?? true
              ? null
              : (m['imageUrl'] as String).trim(),
          rating: (m['rating'] as num?)?.toDouble(),
          subtitle: (m['typeDescription'] as String?)?.trim(),
          isFavorited: m['isFavorited'] as bool? ?? false,
        ));
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }
}
