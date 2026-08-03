import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/api_interfaces.dart';
import 'package:wjplayer/core/services/watch_history/watch_history_matcher.dart';
import 'package:wjplayer/core/services/watch_history/watch_history_models.dart';

void main() {
  group('watch history matcher', () {
    test('matches movies strongly when tmdb and title align', () {
      final record = WatchHistoryRecord(
        recordId: 'r1',
        scopeKey: 'server:user',
        mediaKind: WatchHistoryMediaKind.movie,
        canonicalKey: 'movie:tmdb:129',
        tmdbId: '129',
        title: '千与千寻',
        lastPositionTicks: 1200000000,
        played: false,
        playCount: 1,
        lastPlayedAt: DateTime.utc(2026, 6, 14),
        lastWriteSource: WatchHistoryWriteSource.internalPlayer,
      );
      final candidate = MediaItem(
        id: 'movie-1',
        name: '千与千寻',
        type: 'Movie',
        providerIds: const {'Tmdb': '129'},
        productionYear: 2001,
      );

      final result = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: candidate,
        uniqueCandidate: true,
      );

      expect(result.confidence, WatchHistoryMatchConfidence.strong);
    });

    test('treats unique title and year fallback as possible match', () {
      final record = WatchHistoryRecord(
        recordId: 'r2',
        scopeKey: 'server:user',
        mediaKind: WatchHistoryMediaKind.movie,
        canonicalKey: 'movie:title:summerwars:year:2009',
        title: 'Summer Wars',
        year: 2009,
        lastPositionTicks: 900000000,
        played: false,
        playCount: 1,
        lastPlayedAt: DateTime.utc(2026, 6, 14),
        lastWriteSource: WatchHistoryWriteSource.internalPlayer,
      );
      final candidate = MediaItem(
        id: 'movie-2',
        name: 'Summer Wars',
        type: 'Movie',
        productionYear: 2009,
      );

      final result = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: candidate,
        uniqueCandidate: true,
      );

      expect(result.confidence, WatchHistoryMatchConfidence.possible);
    });

    test('matches episodes strongly when series tmdb and episode index align',
        () {
      final record = WatchHistoryRecord(
        recordId: 'r3',
        scopeKey: 'server:user',
        mediaKind: WatchHistoryMediaKind.episode,
        canonicalKey: 'series:tmdb:1001:s01:e03',
        seriesTmdbId: '1001',
        title: '第 3 集',
        seriesTitle: 'My Show',
        seasonNumber: 1,
        episodeNumber: 3,
        lastPositionTicks: 1500000000,
        played: false,
        playCount: 2,
        lastPlayedAt: DateTime.utc(2026, 6, 14),
        lastWriteSource: WatchHistoryWriteSource.internalPlayer,
      );
      final candidate = MediaItem(
        id: 'episode-1',
        name: 'Episode 3',
        type: 'Episode',
        seriesName: 'My Show',
        parentIndexNumber: 1,
        indexNumber: 3,
      );

      final result = matchWatchHistoryRecordToCandidate(
        record: record,
        candidate: candidate,
        candidateSeriesTmdbId: '1001',
        uniqueCandidate: true,
      );

      expect(result.confidence, WatchHistoryMatchConfidence.strong);
    });

    test('builds episode title fallback canonical keys', () {
      final item = MediaItem(
        id: 'episode-2',
        name: '第 3 集',
        type: 'Episode',
        seriesName: 'My Show',
        parentIndexNumber: 1,
        indexNumber: 3,
      );

      final fingerprint = buildWatchHistoryFingerprintFromItem(item);

      expect(fingerprint, isNotNull);
      expect(
        fingerprint!.canonicalKey,
        'episode:title:my show:s01:e03',
      );
    });
  });
}
