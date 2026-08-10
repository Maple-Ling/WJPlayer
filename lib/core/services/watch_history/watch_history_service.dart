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

    // 同一媒体（同电影 / 同系列，跨服务器、跨分集）全局只保留一条记录，
    // 直接全量匹配取「最近一次播放」记录即可，无需区分本服/跨服。
    final all = await _store.loadAll();
    final groupRecords = _findGroupRecords(
      fingerprint: fingerprint,
      item: item,
      all: all,
    );

    WatchHistoryRecord? latest;
    for (final record in groupRecords) {
      if (record.played || record.lastPositionTicks <= 0) continue;
      if (latest == null || record.lastPlayedAt.isAfter(latest.lastPlayedAt)) {
        latest = record;
      }
    }

    var best = normalizedRemotePosition;
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

  /// 找出与当前条目同属一个媒体（同一部电影 / 同一系列剧集）的全部记录，
  /// 按三层匹配递进：
  /// 1. 合并分组 key 精确匹配（TMDB / 标题归一化，跨服务器、跨分集）；
  /// 2. [matchWatchHistoryRecordToCandidate] 模糊匹配（strong/possible，
  ///    覆盖标题归一化差异的跨源场景）；
  /// 3. 标题主干互含兜底（飞牛等文件浏览型源的标题常带 SxxExx/分辨率后缀，
  ///    与 Emby 干净标题不一致时的最后手段）。
  List<WatchHistoryRecord> _findGroupRecords({
    required WatchHistoryFingerprint fingerprint,
    required MediaItem item,
    required List<WatchHistoryRecord> all,
  }) {
    final groupKey = watchHistoryMergeGroupKeyFromFingerprint(fingerprint);
    if (groupKey != null) {
      final exact = all
          .where((record) => watchHistoryMergeGroupKey(record) == groupKey)
          .toList();
      if (exact.isNotEmpty) {
        return exact;
      }
    }

    final matched = <WatchHistoryRecord>[];
    for (final record in all) {
      final match = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: item,
        candidateSeriesTmdbId: fingerprint.seriesTmdbId,
        uniqueCandidate: true,
      );
      if (match.confidence == WatchHistoryMatchConfidence.strong ||
          match.confidence == WatchHistoryMatchConfidence.possible) {
        matched.add(record);
      }
    }
    if (matched.isNotEmpty) {
      return matched;
    }

    return all
        .where((record) => _titleStemOverlap(record, fingerprint))
        .toList();
  }

  /// 标题主干互含：去除 SxxExx / 第x集 / 分辨率等后缀后互含判定。
  bool _titleStemOverlap(
    WatchHistoryRecord record,
    WatchHistoryFingerprint fingerprint,
  ) {
    String stem(String source) {
      return normalizeWatchHistoryText(source
          .replaceAll(RegExp(r'[Ss]\d{1,2}[Ee]\d{1,3}'), ' ')
          .replaceAll(RegExp(r'第\s*\d+\s*[集话]'), ' ')
          .replaceAll(RegExp(r'[第]\d+[季]'), ' '));
    }

    if (fingerprint.mediaKind == WatchHistoryMediaKind.movie) {
      final a = stem(fingerprint.normalizedTitle);
      final b = stem(record.title);
      return a.isNotEmpty &&
          b.isNotEmpty &&
          (a.contains(b) || b.contains(a));
    }
    final a = stem(fingerprint.normalizedSeriesTitle);
    final bRaw = stem(record.seriesTitle ?? '');
    final b = bRaw.isNotEmpty ? bRaw : stem(record.title);
    return a.isNotEmpty &&
        b.isNotEmpty &&
        (a.contains(b) || b.contains(a));
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

    // 同一媒体（同电影/同系列，跨服务器、跨分集）全局只保留一条记录：
    // 覆盖写入时删除同组全部旧记录，新记录以「最后播放的服务器」为 scopeKey。
    final all = await _store.loadAll();
    final groupRecords = _findGroupRecords(
      fingerprint: fingerprint,
      item: item,
      all: all,
    );
    groupRecords.sort(
      (left, right) => right.lastPlayedAt.compareTo(left.lastPlayedAt),
    );
    final existing = groupRecords.isEmpty ? null : groupRecords.first;
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
    // 合并覆盖：累计观看次数取组内历史最大，首次观看时间取组内最早。
    final historyPlayCount = groupRecords.fold<int>(
      0,
      (acc, record) => record.playCount > acc ? record.playCount : acc,
    );
    final nextPlayCount = historyPlayCount +
        (incrementPlayCount || existing == null ? 1 : 0);
    DateTime? firstPlayed;
    for (final record in groupRecords) {
      final candidate = record.effectiveFirstPlayedAt;
      if (firstPlayed == null || candidate.isBefore(firstPlayed)) {
        firstPlayed = candidate;
      }
    }

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
      firstPlayedAt: firstPlayed ?? now,
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

    // 同组旧记录（跨服务器、跨分集）全部替换为最新一条。
    final replacedIds = groupRecords
        .where((old) => old.recordId != record.recordId)
        .map((old) => old.recordId)
        .toList(growable: false);
    await _store.saveRecord(record, replaceRecordIds: replacedIds);
    _lastProgressWriteAt[recordId] = now;
    for (final old in groupRecords) {
      if (old.recordId != recordId) {
        _lastProgressWriteAt.remove(old.recordId);
      }
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
}
