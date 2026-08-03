import 'package:dio/dio.dart';

import '../app_logger.dart';
import 'sync_config.dart';
import 'sync_models.dart';

/// 解析结果：Bangumi 的 subject_id + 该集的 episode_id（真实 ep id，非集号）。
class BangumiEpisodeRef {
  final int subjectId;
  final int episodeId;
  const BangumiEpisodeRef(this.subjectId, this.episodeId);
}

/// 搜索命中的条目：subject + 是否「已是目标季本体」（高可信则不再走续集链）。
class _SubjectMatch {
  final int subjectId;
  final bool seasonMatched;
  const _SubjectMatch(this.subjectId, this.seasonMatched);
}

/// 把 Emby 项目反查成 Bangumi 的 subject/episode —— 不下载任何数据集，
/// 全部走 Bangumi 公开 API：
/// 1. `/v0/search/subjects` 按剧名搜索，再用开播日期（±180天）择优定位本体；
/// 2. 多季时沿「续集」关系链 `/v0/subjects/{id}/subjects` 走到目标季；
/// 3. `/v0/episodes` 按集号取真实 ep id。
///
/// 思路借鉴 SanaeMio/Bangumi-syncer 的 API 回退路径，但去掉了 bangumi-data
/// 离线数据集（7MB+），改为纯在线查询。
class BangumiMatcher {
  static final _logger = AppLogger();
  // 国内加速反代开关生效点（见 sync_config.dart）。
  String get _apiBase => bangumiApiBase;
  static const int _maxSequelHops = 10;
  static const int _episodesPageLimit = 200;
  static const int _dateMatchToleranceDays = 180;

  final Dio _dio;

  BangumiMatcher({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': kSyncUserAgent},
              validateStatus: (_) => true,
            ));

  // ============ 对外入口 ============

  /// 解析剧集 → (subject_id, episode_id)。失败返回 null（静默跳过）。
  Future<BangumiEpisodeRef?> resolveEpisode({
    required String title,
    String? originalTitle,
    DateTime? airDate,
    required int season,
    required int episode,
  }) async {
    final match = await _searchSubject(
      title: title,
      originalTitle: originalTitle,
      airDate: airDate,
      season: season,
      isMovie: false,
    );
    if (match == null) return null;

    var subjectId = match.subjectId;
    if (season > 1 && !match.seasonMatched) {
      final resolved = await _resolveSeasonSubjectId(match.subjectId, season);
      if (resolved == null) {
        _logger.w('BangumiMatcher', '续集链未走到第$season季: root=${match.subjectId}');
        return null;
      }
      subjectId = resolved;
    }

    final epId = await _findEpisodeIdBySort(subjectId, episode);
    if (epId == null) return null;
    return BangumiEpisodeRef(subjectId, epId);
  }

  /// 解析电影 → (subject_id, 主章节 episode_id)。
  Future<BangumiEpisodeRef?> resolveMovie({
    required String title,
    String? originalTitle,
    DateTime? airDate,
  }) async {
    final match = await _searchSubject(
      title: title,
      originalTitle: originalTitle,
      airDate: airDate,
      season: 1,
      isMovie: true,
    );
    if (match == null) return null;
    final epId = await _findEpisodeIdBySort(match.subjectId, 1);
    if (epId == null) return null;
    return BangumiEpisodeRef(match.subjectId, epId);
  }

  // ============ 标题搜索 → subject ============

  Future<_SubjectMatch?> _searchSubject({
    required String title,
    String? originalTitle,
    DateTime? airDate,
    required int season,
    required bool isMovie,
  }) async {
    final queries = <String>{
      if (season > 1) _stripSeasonSuffix(title) else title,
      title,
      if (originalTitle != null && originalTitle.isNotEmpty) originalTitle,
    }.where((s) => s.trim().isNotEmpty);

    for (final q in queries) {
      final results = await _searchBgm(q);
      if (results.isEmpty) continue;

      // 按开播日期与 airDate 择优。
      Map? best;
      var bestDiff = 1 << 30;
      for (final r in results) {
        final id = (r['id'] as num?)?.toInt();
        if (id == null) continue;
        final date = _parseDate(r['date']?.toString());
        if (airDate != null && date != null) {
          final diff = date.difference(airDate).inDays.abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            best = r;
          }
        }
      }

      if (best != null && bestDiff <= _dateMatchToleranceDays) {
        // 日期高度吻合：基本可断定就是这一季本体，无需再走续集链。
        return _SubjectMatch((best['id'] as num).toInt(), true);
      }

      // 日期对不上（或无日期）：退回第一个结果。若标题已含季度信息，视为季本体。
      final first = results.first;
      final id = (first['id'] as num?)?.toInt();
      if (id == null) continue;
      final name = '${first['name'] ?? ''} ${first['name_cn'] ?? ''}';
      final seasonMatched =
          season <= 1 || _titleHasSeasonInfo(name, season);
      return _SubjectMatch(id, seasonMatched);
    }
    return null;
  }

  /// 调 Bangumi 搜索接口，返回候选条目列表（含 id/name/name_cn/date）。
  Future<List<Map>> _searchBgm(String keyword) async {
    // 新版接口：POST /v0/search/subjects（type 2 = 动画）。
    try {
      final resp = await _dio.post(
        '$_apiBase/v0/search/subjects',
        queryParameters: {'limit': 10},
        data: {
          'keyword': keyword,
          'filter': {
            'type': [2],
            'nsfw': true,
          },
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      if ((resp.statusCode ?? 0) == 200 && resp.data is Map) {
        final data = (resp.data as Map)['data'];
        if (data is List) return data.whereType<Map>().toList();
      }
    } catch (e) {
      _logger.w('BangumiMatcher', 'v0 搜索失败「$keyword」: $e');
    }

    // 回退旧接口：GET /search/subject/{keyword}?type=2。
    try {
      final resp = await _dio.get(
        '$_apiBase/search/subject/${Uri.encodeComponent(keyword)}',
        queryParameters: {'type': 2, 'responseGroup': 'small'},
      );
      if ((resp.statusCode ?? 0) == 200 && resp.data is Map) {
        final list = (resp.data as Map)['list'];
        if (list is List) return list.whereType<Map>().toList();
      }
    } catch (e) {
      _logger.w('BangumiMatcher', '旧版搜索失败「$keyword」: $e');
    }
    return const [];
  }

  /// 已知 subject_id 时，按集号取真实 ep id（供弹弹play 反查路径复用）。
  Future<int?> findEpisodeId(int subjectId, int episode) =>
      _findEpisodeIdBySort(subjectId, episode);

  // ============ 续集链 / 集数解析 ============

  /// 沿「续集」关系链从 [rootId] 走到第 [season] 季的 subject_id。
  Future<int?> _resolveSeasonSubjectId(int rootId, int season) async {
    if (season <= 1) return rootId;
    if (season - 1 > _maxSequelHops) return null; // 防御异常季号导致狂刷接口
    var current = rootId;
    for (var s = 1; s < season; s++) {
      final next = await _nextSequelSubjectId(current);
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  Future<int?> _nextSequelSubjectId(int subjectId) async {
    try {
      final resp = await _dio.get('$_apiBase/v0/subjects/$subjectId/subjects');
      if ((resp.statusCode ?? 0) != 200) return null;
      final data = resp.data;
      final list = data is List ? data : (data is Map ? data['data'] : null);
      if (list is! List) return null;
      for (final rel in list) {
        if (rel is Map && rel['relation'] == '续集') {
          return int.tryParse((rel['id'] ?? '').toString());
        }
      }
    } catch (e) {
      _logger.w('BangumiMatcher', '取续集失败 subject=$subjectId: $e');
    }
    return null;
  }

  /// 在 subject 内按集号（sort/ep）找到真实 ep id。
  Future<int?> _findEpisodeIdBySort(int subjectId, int targetSort) async {
    try {
      var offset = 0;
      while (offset < _episodesPageLimit * 5) {
        final resp = await _dio.get('$_apiBase/v0/episodes', queryParameters: {
          'subject_id': subjectId,
          'type': 0, // 本篇
          'limit': _episodesPageLimit,
          'offset': offset,
        });
        if ((resp.statusCode ?? 0) != 200 || resp.data is! Map) return null;
        final data = (resp.data as Map)['data'];
        if (data is! List || data.isEmpty) return null;
        for (final ep in data) {
          if (ep is! Map) continue;
          final sort = (ep['sort'] as num?)?.toInt();
          final epNo = (ep['ep'] as num?)?.toInt();
          if (sort == targetSort || epNo == targetSort) {
            return int.tryParse((ep['id'] ?? '').toString());
          }
        }
        if (data.length < _episodesPageLimit) return null;
        offset += _episodesPageLimit;
      }
    } catch (e) {
      _logger.w('BangumiMatcher', '取章节失败 subject=$subjectId: $e');
    }
    return null;
  }

  // ============ 工具 ============

  /// 检查标题是否包含第 N 季信息（移植自 Bangumi-syncer）。
  bool _titleHasSeasonInfo(String title, int season) {
    const cn = {
      1: '一', 2: '二', 3: '三', 4: '四', 5: '五',
      6: '六', 7: '七', 8: '八', 9: '九', 10: '十',
    };
    final keywords = <String>[
      '第$season季', '第$season期', '$season季', '$season期',
      'Season $season', 'S$season',
    ];
    final c = cn[season];
    if (c != null) {
      keywords.addAll(['第$c季', '第$c期', '$c季', '$c期']);
    }
    return keywords.any((k) => title.contains(k));
  }

  String _stripSeasonSuffix(String title) {
    var t = title;
    t = t.replaceAll(RegExp(r'\s*第?\s*\d+\s*[期季話话集]\s*$'), '');
    t = t.replaceAll(RegExp(r'\s*Season\s*\d+\s*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s*S\d+\s*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s+II+\s*$'), '');
    t = t.replaceAll(RegExp(r'\s+\d+\s*$'), '');
    final trimmed = t.trim();
    return trimmed.isEmpty ? title : trimmed;
  }

  DateTime? _parseDate(String? value) {
    if (value == null || value.isEmpty) return null;
    final m = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(value);
    if (m == null) return null;
    try {
      return DateTime(
          int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    } catch (_) {
      return null;
    }
  }
}
