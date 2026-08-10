import '../../api/api_interfaces.dart';
import 'watch_history_matcher.dart';
import 'watch_history_merge.dart';
import 'watch_history_models.dart';
import 'watch_history_store.dart';

class WatchHistoryService {
  WatchHistoryService({
    required WatchHistoryStore store,
  }) : _store = store;

  final WatchHistoryStore _store;
  final Map<String, DateTime> _lastProgressWriteAt = <String, DateTime>{};
  final Map<String, Future<String?>> _seriesTmdbCache =
      <String, Future<String?>>{};

  Future<List<WatchHistoryRecord>> loadScope(String scopeKey) {
    return _store.loadScope(scopeKey);
  }

  Future<List<WatchHistoryRecord>> loadAll() {
    return _store.loadAll();
  }

  Future<void> clearAll() {
    _lastProgressWriteAt.clear();
    return _store.clearAll();
  }

  Future<void> deleteRecord(String recordId) {
    _lastProgressWriteAt.remove(recordId);
    return _store.deleteRecord(recordId);
  }

  /// 删除同一媒体的整组播放记录（跨服务器 + 全部分集）。
  /// 记录页合并卡片后删除以媒体为单位，避免残留「幽灵」记录。
  Future<void> deleteMediaGroup(WatchHistoryRecord representative) async {
    final key = watchHistoryMergeGroupKey(representative);
    final all = await _store.loadAll();
    final ids = all
        .where((record) => watchHistoryMergeGroupKey(record) == key)
        .map((record) => record.recordId)
        .toSet();
    for (final id in ids) {
      _lastProgressWriteAt.remove(id);
    }
    await _store.deleteRecords(ids);
  }

  Future<WatchHistoryFingerprint?> buildFingerprint(
    ApiClientFactory api,
    MediaItem item,
  ) async {
    final seriesTmdbId = await resolveSeriesTmdbId(api, item);
    return buildWatchHistoryFingerprintFromItem(
      item,
      seriesTmdbId: seriesTmdbId,
    );
  }

  Future<int?> resolveResumePositionTicks({
    required String scopeKey,
    required ApiClientFactory api,
    required MediaItem item,
    int? remotePositionTicks,
    bool remotePlayed = false,
    bool crossServer = false,
  }) async {
    if (remotePlayed) {
      return null;
    }

    final normalizedRemotePosition = _normalizePositionTicks(
      remotePositionTicks,
      item.runTimeTicks,
    );
    final fingerprint = await buildFingerprint(api, item);
    if (fingerprint == null) {
      return normalizedRemotePosition;
    }

    final records = await _store.loadScope(scopeKey);
    final existing = _findExistingRecord(records, fingerprint, item.id);

    // 本服已标记看完时不续播（包括跨服务器场景，避免覆盖用户在此服的“已看完”）。
    if (existing != null && existing.played) {
      return normalizedRemotePosition;
    }

    // 候选进度：远端进度 + 本地记录进度。本地记录（本服 + 可选其它服务器）统一
    // 按「最近一次播放」取——用户切换到其它服务器重新观看时，旧服务器更远的
    // 进度**不应**覆盖新进度（原实现跨服务器取最大进度导致永远续到旧服务器）。
    var best = normalizedRemotePosition;
    WatchHistoryRecord? latest =
        (existing != null && !existing.played && existing.lastPositionTicks > 0)
            ? existing
            : null;

    if (crossServer) {
      final cross = await _resolveLatestCrossServerRecord(
        api: api,
        item: item,
        currentScopeKey: scopeKey,
      );
      if (cross != null &&
          (latest == null || cross.lastPlayedAt.isAfter(latest.lastPlayedAt))) {
        latest = cross;
      }
    }

    if (latest != null) {
      best = _maxPositionTicks(
        best,
        _normalizePositionTicks(
          latest.lastPositionTicks,
          item.runTimeTicks ?? latest.runTimeTicks,
        ),
      );
    }

    return best;
  }

  /// 扫描其它服务器（scope）下的观看记录，找出与当前条目匹配的
  /// **最近一次播放**（lastPlayedAt 最新）的记录，用于续播。
  ///
  /// 复用 [matchWatchHistoryRecordToCandidate]：因为 canonicalKey/指纹与服务器无关
  /// （基于 TMDB / PresentationUniqueKey / 剧名+季集号等），同一部影片或同一集在
  /// 不同服务器之间也能匹配上。仅采用 strong / possible 级别，避免误续播。
  Future<WatchHistoryRecord?> _resolveLatestCrossServerRecord({
    required ApiClientFactory api,
    required MediaItem item,
    required String currentScopeKey,
  }) async {
    final all = await _store.loadAll();
    if (all.isEmpty) {
      return null;
    }
    final seriesTmdbId = await resolveSeriesTmdbId(api, item);

    WatchHistoryRecord? best;
    for (final record in all) {
      // 本服记录已在上层处理。
      if (record.scopeKey == currentScopeKey) {
        continue;
      }
      if (record.played || record.lastPositionTicks <= 0) {
        continue;
      }
      final match = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: item,
        candidateSeriesTmdbId: seriesTmdbId,
        uniqueCandidate: true,
      );
      if (match.confidence != WatchHistoryMatchConfidence.strong &&
          match.confidence != WatchHistoryMatchConfidence.possible) {
        continue;
      }
      if (best == null || record.lastPlayedAt.isAfter(best.lastPlayedAt)) {
        best = record;
      }
    }
    return best;
  }

  int? _maxPositionTicks(int? left, int? right) {
    if (left == null) return right;
    if (right == null) return left;
    return left > right ? left : right;
  }

  Future<String?> resolveSeriesTmdbId(
    ApiClientFactory api,
    MediaItem item,
  ) async {
    if (item.type.toLowerCase() != 'episode') {
      return null;
    }
    final seriesId = item.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return null;
    }
    final pending = _seriesTmdbCache.putIfAbsent(seriesId, () async {
      try {
        final seriesItem = await api.media.getItemDetails(seriesId);
        return extractProviderId(seriesItem.providerIds, 'tmdb');
      } catch (_) {
        return null;
      }
    });
    return pending;
  }

  Future<WatchHistoryRecord?> capturePlayback({
    required String scopeKey,
    required ApiClientFactory api,
    required MediaItem item,
    required int positionTicks,
    required WatchHistoryWriteSource source,
    required int watchedThresholdPercent,
    String? sourceEntryId,
    String? sourcePosterUrl,
    String? playerCore,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    final fingerprint = await buildFingerprint(api, item);
    if (fingerprint == null) {
      return null;
    }

    // Episode 记录统一使用剧集主海报，而不是单集 still/episode poster。
    // 这样历史列表、继续观看和记录页都保持影视级封面。
    var historyPosterUrl = sourcePosterUrl;
    if (item.type.toLowerCase() == 'episode' &&
        item.seriesId != null &&
        item.seriesId!.isNotEmpty) {
      try {
        final series = await api.media.getItemDetails(item.seriesId!);
        final tag = series.primaryImageTag;
        if (tag != null && tag.isNotEmpty) {
          historyPosterUrl = api.image.getPrimaryImageUrl(
            series.id,
            tag: tag,
            maxWidth: 640,
          );
        }
      } catch (_) {
        // 系列封面获取失败时保留原图，不影响记录保存。
      }
    }

    final records = await _store.loadScope(scopeKey);
    final existing = _findExistingRecord(records, fingerprint, item.id);
    final recordId = buildWatchHistoryRecordId(
      scopeKey: scopeKey,
      mediaKind: fingerprint.mediaKind,
      canonicalKey: fingerprint.canonicalKey,
    );

    if (!force &&
        existing != null &&
        !incrementPlayCount &&
        !_shouldPersistProgress(recordId)) {
      return existing;
    }

    final now = DateTime.now().toUtc();
    final played = _isPlayed(
      positionTicks: positionTicks,
      runTimeTicks: item.runTimeTicks,
      watchedThresholdPercent: watchedThresholdPercent,
    );
    final nextPlayCount = (existing?.playCount ?? 0) +
        (incrementPlayCount || existing == null ? 1 : 0);

    final record = WatchHistoryRecord(
      recordId: recordId,
      scopeKey: scopeKey,
      mediaKind: fingerprint.mediaKind,
      canonicalKey: fingerprint.canonicalKey,
      tmdbId: fingerprint.tmdbId,
      seriesTmdbId: fingerprint.seriesTmdbId,
      title: item.name,
      seriesTitle: item.seriesName,
      seasonNumber: item.parentIndexNumber,
      episodeNumber: item.indexNumber,
      year: item.productionYear,
      lastPositionTicks: positionTicks.clamp(
        0,
        item.runTimeTicks ?? positionTicks,
      ),
      runTimeTicks: item.runTimeTicks,
      played: played,
      playCount: nextPlayCount,
      lastPlayedAt: now,
      firstPlayedAt: existing?.firstPlayedAt ?? existing?.lastPlayedAt ?? now,
      lastEmbyItemId: item.id,
      matchConfidence:
          existing?.matchConfidence ?? WatchHistoryMatchConfidence.none,
      restoredAt: existing?.restoredAt,
      lastWriteSource: source,
      presentationUniqueKey: item.presentationUniqueKey,
      mediaPath: item.path,
      sourceEntryId: sourceEntryId ?? existing?.sourceEntryId,
      sourcePosterUrl: historyPosterUrl ?? existing?.sourcePosterUrl,
      playerCore: playerCore ?? existing?.playerCore,
      seriesEntryId: item.seriesId ?? existing?.seriesEntryId,
    );

    final replacedIds = <String>[
      if (existing != null && existing.recordId != record.recordId)
        existing.recordId,
      if (fingerprint.mediaKind == WatchHistoryMediaKind.episode)
        for (final old in records)
          if (old.recordId != record.recordId &&
              old.mediaKind == WatchHistoryMediaKind.episode &&
              ((fingerprint.seriesTmdbId?.isNotEmpty == true &&
                      old.seriesTmdbId == fingerprint.seriesTmdbId) ||
                  (fingerprint.normalizedSeriesTitle.isNotEmpty &&
                      normalizeWatchHistoryText(old.seriesTitle ?? '') ==
                          fingerprint.normalizedSeriesTitle)))
            old.recordId,
    ];
    await _store.saveRecord(record, replaceRecordIds: replacedIds);
    _lastProgressWriteAt[recordId] = now;
    if (existing != null && existing.recordId != recordId) {
      _lastProgressWriteAt.remove(existing.recordId);
    }
    return record;
  }

  bool _isPlayed({
    required int positionTicks,
    required int? runTimeTicks,
    required int watchedThresholdPercent,
  }) {
    final runtime = runTimeTicks;
    if (runtime == null || runtime <= 0) {
      return false;
    }
    final ratio = positionTicks / runtime;
    return ratio >= watchedThresholdPercent / 100;
  }

  bool _shouldPersistProgress(String recordId) {
    final lastWriteAt = _lastProgressWriteAt[recordId];
    if (lastWriteAt == null) {
      return true;
    }
    return DateTime.now().toUtc().difference(lastWriteAt).inSeconds >= 10;
  }

  int? _normalizePositionTicks(int? positionTicks, int? runtimeTicks) {
    if (positionTicks == null || positionTicks <= 0) {
      return null;
    }
    if (runtimeTicks == null || runtimeTicks <= 0) {
      return positionTicks;
    }
    return positionTicks.clamp(0, runtimeTicks);
  }

  WatchHistoryRecord? _findExistingRecord(
    List<WatchHistoryRecord> records,
    WatchHistoryFingerprint fingerprint,
    String itemId,
  ) {
    if (fingerprint.mediaKind == WatchHistoryMediaKind.episode) {
      final seriesKey = fingerprint.seriesTmdbId?.trim();
      final seriesTitle = fingerprint.normalizedSeriesTitle;
      for (final record in records) {
        if (record.mediaKind != WatchHistoryMediaKind.episode) continue;
        if (seriesKey?.isNotEmpty == true && record.seriesTmdbId == seriesKey) {
          return record;
        }
        if (seriesTitle.isNotEmpty &&
            normalizeWatchHistoryText(record.seriesTitle ?? '') == seriesTitle) {
          return record;
        }
      }
    }
    for (final record in records) {
      if (record.canonicalKey == fingerprint.canonicalKey) {
        return record;
      }
    }
    for (final record in records) {
      if (record.lastEmbyItemId == itemId) {
        return record;
      }
    }
    final candidatePuk = fingerprint.normalizedPresentationUniqueKey;
    if (candidatePuk != null && candidatePuk.isNotEmpty) {
      for (final record in records) {
        final recordPuk =
            normalizePresentationUniqueKey(record.presentationUniqueKey);
        if (recordPuk == candidatePuk) {
          return record;
        }
      }
    }
    return null;
  }
}
