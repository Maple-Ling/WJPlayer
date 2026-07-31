import '../../api/api_interfaces.dart';
import '../../api/danmaku/danmaku_source.dart';
import '../app_logger.dart';
import 'bangumi_matcher.dart';
import 'bangumi_sync_service.dart';
import 'sync_models.dart';
import 'trakt_sync_service.dart';

/// 一次观看上报的结果：每个已连接服务是否成功写入。
class SyncScrobbleResult {
  final Map<SyncService, bool> results;
  const SyncScrobbleResult(this.results);

  bool get anySucceeded => results.values.any((ok) => ok);
  bool succeeded(SyncService service) => results[service] ?? false;
}

/// 观看记录自动同步：把「已看完的影片/剧集」映射成 Trakt/Bangumi 的写入调用。
///
/// 仅对「已连接」的服务上报（连接与否 = 用户的开关）。
/// - Trakt：直接用 Emby ProviderIds——影片 imdb/tmdb，剧集 tvdb/tmdb/imdb。
/// - Bangumi 反查 subject/episode，三级回退：
///   1. Emby 自带 Bangumi providerId（最快）；
///   2. 弹弹play：文件名/剧名匹配作品 → 详情 `bangumiUrl` 抠 subject id（首选）；
///   3. Bangumi API：`/v0/search/subjects` + 开播日期择优 + 续集链（兜底）。
///   全部失败则静默跳过，不影响播放与 Trakt。
class SyncScrobbleService {
  static final _logger = AppLogger();

  final TraktSyncService trakt;
  final BangumiSyncService bangumi;
  final BangumiMatcher bangumiMatcher;

  SyncScrobbleService({
    TraktSyncService? trakt,
    BangumiSyncService? bangumi,
    BangumiMatcher? bangumiMatcher,
  })  : trakt = trakt ?? TraktSyncService(),
        bangumi = bangumi ?? BangumiSyncService(),
        bangumiMatcher = bangumiMatcher ?? BangumiMatcher();

  /// Trakt scrobble 生命周期（start/pause/stop）。仅需影片自身的 ProviderIds，
  /// 不做任何耗时的反查，供 onStart/onStop 直接调用。未连 Trakt 时静默返回。
  Future<void> traktScrobble(
    MediaItem item,
    TraktScrobbleAction action,
    double progress,
  ) async {
    if (SyncSession.current(SyncService.trakt) == null) return;
    final type = _traktType(item);
    if (type == null) return;
    final ids = _traktIds(item.providerIds);
    if (ids.isEmpty) {
      _logger.w('SyncScrobble', 'Trakt 跳过 ${item.name}: 无可用 ProviderIds');
      return;
    }
    await trakt.scrobble(
        type: type, ids: ids, progress: progress, action: action);
  }

  /// 播放停止时上报。Trakt 总是发 scrobble/stop（由其按 [progress] 判定看过/续播点）；
  /// Bangumi 仅在 [reachedThreshold]（进度达到观看阈值）时标记「在看 + 单集看过」。
  /// [seriesProviderIds] 为剧集所属剧的 ProviderIds（Bangumi 取 subject 用）。
  /// [dandanplay] 在线时作为 Bangumi 反查的首选来源。
  Future<SyncScrobbleResult> scrobbleStop(
    MediaItem item, {
    required double progress,
    required bool reachedThreshold,
    Map<String, String>? seriesProviderIds,
    DandanplaySource? dandanplay,
  }) async {
    final out = <SyncService, bool>{};

    if (SyncSession.current(SyncService.trakt) != null) {
      final type = _traktType(item);
      final ids = _traktIds(item.providerIds);
      if (type != null && ids.isNotEmpty) {
        out[SyncService.trakt] = await trakt.scrobble(
            type: type,
            ids: ids,
            progress: progress,
            action: TraktScrobbleAction.stop);
      }
    }
    if (reachedThreshold && SyncSession.current(SyncService.bangumi) != null) {
      final ok = await _scrobbleBangumi(item, seriesProviderIds, dandanplay);
      if (ok != null) out[SyncService.bangumi] = ok;
    }

    if (out.isNotEmpty) {
      _logger.i('SyncScrobble', '停止上报 ${item.name}: $out');
    }
    return SyncScrobbleResult(out);
  }

  // ---- Trakt ----

  String? _traktType(MediaItem item) => switch (item.type) {
        'Movie' => 'movie',
        'Episode' => 'episode',
        _ => null,
      };

  /// Emby ProviderIds（如 {'Tmdb':'123','Imdb':'tt...'}）→ Trakt ids 对象。
  Map<String, dynamic> _traktIds(Map<String, String>? p) {
    final out = <String, dynamic>{};
    if (p == null) return out;
    p.forEach((k, v) {
      if (v.isEmpty) return;
      switch (k.toLowerCase()) {
        case 'imdb':
          out['imdb'] = v;
          break;
        case 'tmdb':
          out['tmdb'] = int.tryParse(v) ?? v;
          break;
        case 'tvdb':
          out['tvdb'] = int.tryParse(v) ?? v;
          break;
        case 'trakt':
          out['trakt'] = int.tryParse(v) ?? v;
          break;
      }
    });
    return out;
  }

  // ---- Bangumi ----

  Future<bool?> _scrobbleBangumi(
    MediaItem item,
    Map<String, String>? seriesProviderIds,
    DandanplaySource? dandanplay,
  ) async {
    // Bangumi 以「单集」为粒度，需要 subject_id + episode_id。
    if (item.type != 'Episode') return null;

    final ref = await _resolveBangumi(item, seriesProviderIds, dandanplay);
    if (ref == null) {
      _logger.w('SyncScrobble', 'Bangumi 跳过 ${item.name}: 未匹配到条目');
      return null;
    }

    // 先确保条目在收藏中（设「在看」）：这是 Bangumi 的招牌追番状态，也是更新单集
    // 进度的前提——未收藏的番直接更新单集会失败。
    // ponytail: 每次都写「在看」，重看已「看过」的番会被降回「在看」（罕见，可接受）。
    await bangumi.setCollectionType(subjectId: ref.subjectId, type: 3);
    return bangumi.updateEpisodeStatus(
      subjectId: ref.subjectId,
      episodeId: ref.episodeId,
      type: 2,
    );
  }

  /// 三级回退把剧集反查成 Bangumi 的 (subject_id, episode_id)。
  Future<BangumiEpisodeRef?> _resolveBangumi(
    MediaItem item,
    Map<String, String>? seriesProviderIds,
    DandanplaySource? dandanplay,
  ) async {
    // 一级：Emby 自带 Bangumi providerId（剧给 subject、集给 episode），最快最准。
    final directEp = _bangumiId(item.providerIds);
    final directSubject = _bangumiId(seriesProviderIds);
    if (directEp != null && directSubject != null) {
      return BangumiEpisodeRef(directSubject, directEp);
    }

    final episode = item.indexNumber;
    if (episode == null) return null;

    // 二级（首选）：弹弹play 反查 —— 文件名/剧名匹配作品 → 作品详情的 bangumiUrl
    // 抠出 bgm subject id（弹弹play 作品按季拆分、直链 bgm，省去续集链猜测）。
    if (dandanplay != null) {
      final subjectId = await _resolveSubjectViaDandanplay(item, dandanplay);
      if (subjectId != null) {
        final epId = await bangumiMatcher.findEpisodeId(subjectId, episode);
        if (epId != null) return BangumiEpisodeRef(subjectId, epId);
      }
    }

    // 三级（兜底）：纯 Bangumi API 搜索（剧名 + 开播日期）+ 续集链定位季度。
    return bangumiMatcher.resolveEpisode(
      title: item.seriesName ?? item.name,
      airDate: item.premiereDate,
      season: item.parentIndexNumber ?? 1,
      episode: episode,
    );
  }

  /// 用弹弹play 反查 bgm.tv subject id：先按文件名匹配作品（最准），失败再按剧名
  /// 搜索；拿到弹弹play animeId 后取作品详情，从 `bangumiUrl` 解析出 subject id。
  Future<int?> _resolveSubjectViaDandanplay(
    MediaItem item,
    DandanplaySource ddp,
  ) async {
    try {
      String? animeId;

      final fileName = _baseName(item.path);
      if (fileName != null && fileName.isNotEmpty) {
        final m = await ddp.match(fileName: fileName);
        if (m.isMatched && m.matches.isNotEmpty) {
          animeId = m.matches.first.animeId;
        }
      }

      if (animeId == null || animeId.isEmpty) {
        final title = item.seriesName ?? item.name;
        final r = await ddp.searchAnime(keyword: title);
        animeId = _pickAnime(r.animes, title, item.productionYear)?.animeId;
      }

      if (animeId == null || animeId.isEmpty) return null;
      final detail = await ddp.getBangumiDetails(bangumiId: animeId);
      return _extractBgmSubjectId(detail.bangumiUrl);
    } catch (e) {
      _logger.w('SyncScrobble', '弹弹play 反查失败 ${item.name}: $e');
      return null;
    }
  }

  /// 从搜索结果里挑最贴近的作品：标题完全相同优先，其次年份吻合，再退第一个。
  DanmakuAnime? _pickAnime(List<DanmakuAnime> animes, String title, int? year) {
    if (animes.isEmpty) return null;
    DanmakuAnime? yearHit;
    for (final a in animes) {
      if (a.animeTitle == title) return a;
      if (year != null && a.year == year) yearHit ??= a;
    }
    return yearHit ?? animes.first;
  }

  int? _extractBgmSubjectId(String? bangumiUrl) {
    if (bangumiUrl == null || bangumiUrl.isEmpty) return null;
    final m = RegExp(r'/subject/(\d+)').firstMatch(bangumiUrl);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  String? _baseName(String? path) {
    if (path == null || path.isEmpty) return null;
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  int? _bangumiId(Map<String, String>? p) {
    if (p == null) return null;
    for (final e in p.entries) {
      if (e.key.toLowerCase() == 'bangumi' && e.value.isNotEmpty) {
        return int.tryParse(e.value);
      }
    }
    return null;
  }
}
