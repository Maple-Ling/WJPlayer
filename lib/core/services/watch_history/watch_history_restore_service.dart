import '../../api/api_interfaces.dart';
import 'watch_history_matcher.dart';
import 'watch_history_models.dart';
import 'watch_history_service.dart';
import 'watch_history_store.dart';

class WatchHistoryRestoreService {
  WatchHistoryRestoreService({
    required WatchHistoryStore store,
    required WatchHistoryService historyService,
  })  : _store = store,
        _historyService = historyService;

  static const int _maxScanRecords = 15;
  static const int _positionToleranceTicks = 30 * 10000000;

  final WatchHistoryStore _store;
  final WatchHistoryService _historyService;

  Future<WatchHistoryRestoreScanResult> scanAndRestore({
    required String scopeKey,
    required ApiClientFactory api,
  }) async {
    final records = await _store.loadScope(scopeKey);
    if (records.isEmpty) {
      return const WatchHistoryRestoreScanResult(
        promptCandidates: [],
        autoRestoredCount: 0,
      );
    }

    final pendingUpdates = <String, WatchHistoryRecord>{};
    final promptCandidates = <WatchHistoryRestoreCandidate>[];
    var autoRestoredCount = 0;

    for (final record in records.take(_maxScanRecords)) {
      final resolved = await _resolveCandidate(api, record);
      if (resolved == null) {
        continue;
      }

      final update = record.copyWith(
        lastEmbyItemId: resolved.item.id,
        matchConfidence: resolved.result.confidence,
      );

      if (!_needsRestore(record, resolved.item)) {
        pendingUpdates[record.recordId] = update;
        continue;
      }

      if (resolved.result.confidence == WatchHistoryMatchConfidence.strong) {
        final restored = await restoreCandidate(
          api: api,
          candidate: WatchHistoryRestoreCandidate(
            record: update,
            matchedItem: resolved.item,
            confidence: resolved.result.confidence,
            reason: resolved.result.reason,
          ),
        );
        if (restored) {
          autoRestoredCount++;
          pendingUpdates[record.recordId] = update.copyWith(
            restoredAt: DateTime.now().toUtc(),
            matchConfidence: WatchHistoryMatchConfidence.strong,
          );
        }
        continue;
      }

      if (resolved.result.confidence == WatchHistoryMatchConfidence.possible) {
        final candidate = WatchHistoryRestoreCandidate(
          record: update,
          matchedItem: resolved.item,
          confidence: resolved.result.confidence,
          reason: resolved.result.reason,
        );
        promptCandidates.add(candidate);
        pendingUpdates[record.recordId] = update;
      }
    }

    if (pendingUpdates.isNotEmpty) {
      await _store.saveRecords(pendingUpdates.values);
    }

    return WatchHistoryRestoreScanResult(
      promptCandidates: promptCandidates,
      autoRestoredCount: autoRestoredCount,
    );
  }

  Future<bool> restoreCandidate({
    required ApiClientFactory api,
    required WatchHistoryRestoreCandidate candidate,
  }) async {
    final record = candidate.record;
    final item = candidate.matchedItem;

    try {
      if (record.played) {
        await api.user.markAsPlayed(item.id);
      } else {
        final positionTicks = record.lastPositionTicks;
        if (positionTicks <= 0) {
          return false;
        }
        await api.playback.reportPlaybackStart(
          PlaybackStartInfo(
            itemId: item.id,
            mediaSourceId: item.id,
          ),
        );
        await api.playback.reportPlaybackProgress(
          PlaybackProgressInfo(
            itemId: item.id,
            mediaSourceId: item.id,
            positionTicks: positionTicks,
            isPaused: true,
          ),
        );
        await api.playback.reportPlaybackStopped(
          PlaybackStopInfo(
            itemId: item.id,
            mediaSourceId: item.id,
            positionTicks: positionTicks,
          ),
        );
      }
    } catch (_) {
      if (!record.played) {
        return false;
      }
      final runtime = item.runTimeTicks ?? record.runTimeTicks;
      if (runtime == null || runtime <= 0) {
        return false;
      }
      try {
        await api.playback.reportPlaybackStart(
          PlaybackStartInfo(
            itemId: item.id,
            mediaSourceId: item.id,
          ),
        );
        await api.playback.reportPlaybackStopped(
          PlaybackStopInfo(
            itemId: item.id,
            mediaSourceId: item.id,
            positionTicks: runtime,
          ),
        );
      } catch (_) {
        return false;
      }
    }

    final updated = record.copyWith(
      lastEmbyItemId: item.id,
      restoredAt: DateTime.now().toUtc(),
      matchConfidence: candidate.confidence,
    );
    await _store.saveRecord(updated);
    return true;
  }

  Future<_ResolvedRestoreCandidate?> _resolveCandidate(
    ApiClientFactory api,
    WatchHistoryRecord record,
  ) async {
    final direct = await _tryResolveByLastItemId(api, record);
    if (direct != null) {
      return direct;
    }

    final query = _buildSearchQuery(record);
    if (query == null) {
      return null;
    }

    final results = await _safeSearch(api, query);
    if (results.isEmpty) {
      return null;
    }

    final typed = results
        .where((item) => _matchesRecordType(record, item))
        .take(10)
        .toList(growable: false);
    if (typed.isEmpty) {
      return null;
    }

    final matches = <_ResolvedRestoreCandidate>[];
    for (final item in typed) {
      final seriesTmdbId = await _historyService.resolveSeriesTmdbId(api, item);
      final result = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: item,
        candidateSeriesTmdbId: seriesTmdbId,
        uniqueCandidate: false,
      );
      if (result.confidence != WatchHistoryMatchConfidence.none) {
        matches.add(_ResolvedRestoreCandidate(item: item, result: result));
      }
    }

    if (matches.isEmpty) {
      return null;
    }

    final strongMatches = matches
        .where((entry) =>
            entry.result.confidence == WatchHistoryMatchConfidence.strong)
        .toList(growable: false);
    if (strongMatches.length == 1) {
      return strongMatches.single;
    }
    if (strongMatches.length > 1) {
      return null;
    }

    if (matches.length != 1) {
      return null;
    }

    final single = matches.single;
    final seriesTmdbId =
        await _historyService.resolveSeriesTmdbId(api, single.item);
    final reranked = matchWatchHistoryRecordToCandidate(
      record: record,
      candidate: single.item,
      candidateSeriesTmdbId: seriesTmdbId,
      uniqueCandidate: true,
    );
    return _ResolvedRestoreCandidate(item: single.item, result: reranked);
  }

  Future<_ResolvedRestoreCandidate?> _tryResolveByLastItemId(
    ApiClientFactory api,
    WatchHistoryRecord record,
  ) async {
    final itemId = record.lastEmbyItemId;
    if (itemId == null || itemId.isEmpty) {
      return null;
    }
    try {
      final item = await api.media.getItemDetails(itemId);
      final seriesTmdbId = await _historyService.resolveSeriesTmdbId(api, item);
      final result = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: item,
        candidateSeriesTmdbId: seriesTmdbId,
        uniqueCandidate: true,
      );
      if (result.confidence == WatchHistoryMatchConfidence.none) {
        return null;
      }
      return _ResolvedRestoreCandidate(item: item, result: result);
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaItem>> _safeSearch(
      ApiClientFactory api, String query) async {
    try {
      return await api.search.search(query);
    } catch (_) {
      return const [];
    }
  }

  bool _matchesRecordType(WatchHistoryRecord record, MediaItem item) {
    final kind = watchHistoryMediaKindFromItem(item);
    return kind == record.mediaKind;
  }

  bool _needsRestore(WatchHistoryRecord record, MediaItem item) {
    final userData = item.userData;
    if (record.played) {
      return !(userData?.played ?? false);
    }

    if (userData?.played ?? false) {
      return false;
    }

    final targetTicks = record.lastPositionTicks;
    if (targetTicks <= 0) {
      return false;
    }

    final currentTicks = (userData?.playbackPositionTicks ?? 0).round();
    if (currentTicks <= 0) {
      return true;
    }

    return currentTicks + _positionToleranceTicks < targetTicks;
  }

  String? _buildSearchQuery(WatchHistoryRecord record) {
    final query = switch (record.mediaKind) {
      WatchHistoryMediaKind.movie => record.title,
      WatchHistoryMediaKind.episode => record.seriesTitle ?? record.title,
    };
    if (query.trim().isEmpty) {
      return null;
    }
    return query;
  }
}

class _ResolvedRestoreCandidate {
  const _ResolvedRestoreCandidate({
    required this.item,
    required this.result,
  });

  final MediaItem item;
  final WatchHistoryMatchResult result;
}
