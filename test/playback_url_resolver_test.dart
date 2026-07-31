import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/api_interfaces.dart';
import 'package:wjplayer/core/utils/playback_url_resolver.dart';

void main() {
  group('buildPlaybackSelection', () {
    test('builds direct-play primary and direct-stream fallback for desktop playback', () {
      final playbackInfo = PlaybackInfo(
        itemId: 'item-1',
        mediaSources: [
          MediaSource(
            id: 'source-1',
            container: 'mkv',
            mediaStreams: [
              MediaStream(
                index: 0,
                type: 'Video',
                codec: 'hevc',
              ),
            ],
          ),
        ],
      );

      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: 'item-1',
        playSessionId: 'session-1',
      );

      expect(selection.mediaSource?.id, 'source-1');
      expect(selection.primaryRequest.mediaSourceId, 'source-1');
      expect(selection.primaryRequest.container, 'mkv');
      expect(selection.primaryRequest.allowDirectPlay, isTrue);
      expect(selection.primaryRequest.allowDirectStream, isFalse);
      expect(selection.primaryRequest.allowTranscoding, isFalse);
      expect(selection.primaryRequest.enableAutoStreamCopy, isFalse);
      expect(selection.primaryRequest.enableAutoStreamCopyAudio, isFalse);
      expect(selection.primaryRequest.enableAutoStreamCopyVideo, isFalse);

      final fallback = selection.fallbackRequest;
      expect(fallback, isNotNull);
      expect(fallback!.mediaSourceId, 'source-1');
      expect(fallback.container, 'mkv');
      expect(fallback.allowDirectPlay, isFalse);
      expect(fallback.allowDirectStream, isTrue);
      expect(fallback.allowTranscoding, isFalse);
      expect(fallback.enableAutoStreamCopy, isTrue);
      expect(fallback.enableAutoStreamCopyAudio, isTrue);
      expect(fallback.enableAutoStreamCopyVideo, isTrue);
      expect(selection.fallbackReason, '直连失败后回退到服务端直传流');
    });
  });
}
