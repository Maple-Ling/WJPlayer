import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/services/watch_history/watch_history_models.dart';
import 'package:wjplayer/core/services/watch_history/watch_history_store.dart';

void main() {
  group('WatchHistoryStore', () {
    test('persists, sorts, and deletes records', () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );

      final older = WatchHistoryRecord(
        recordId: 'older',
        scopeKey: 'server:user',
        mediaKind: WatchHistoryMediaKind.movie,
        canonicalKey: 'movie:tmdb:1',
        tmdbId: '1',
        title: 'Older',
        lastPositionTicks: 100,
        played: false,
        playCount: 1,
        lastPlayedAt: DateTime.utc(2026, 6, 13, 12),
        lastWriteSource: WatchHistoryWriteSource.internalPlayer,
      );
      final newer = WatchHistoryRecord(
        recordId: 'newer',
        scopeKey: 'server:user',
        mediaKind: WatchHistoryMediaKind.movie,
        canonicalKey: 'movie:tmdb:2',
        tmdbId: '2',
        title: 'Newer',
        lastPositionTicks: 200,
        played: false,
        playCount: 1,
        lastPlayedAt: DateTime.utc(2026, 6, 14, 12),
        lastWriteSource: WatchHistoryWriteSource.internalPlayer,
      );

      await store.saveRecord(older);
      await store.saveRecord(newer);

      final records = await store.loadScope('server:user');
      expect(records.map((record) => record.recordId), ['newer', 'older']);

      await store.deleteRecord('newer');

      final afterDelete = await store.loadScope('server:user');
      expect(afterDelete.map((record) => record.recordId), ['older']);
      expect(
        File('${tempDir.path}${Platform.pathSeparator}watch_history.json')
            .existsSync(),
        isTrue,
      );
    });
  });
}
