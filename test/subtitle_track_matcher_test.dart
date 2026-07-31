import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/services/subtitle_track_matcher.dart';

void main() {
  bool titlesMatch(String expected, String actual) {
    final e = expected.toLowerCase();
    final a = actual.toLowerCase();
    return e == a || e.contains(a) || a.contains(e);
  }

  group('SubtitleTrackMatcher', () {
    test('classifies bitmap subtitle codecs reported by mpv', () {
      expect(
        SubtitleTrackMatcher.classifyKind(codec: 'hdmv_pgs_subtitle'),
        SubtitleKind.bitmap,
      );
      expect(SubtitleTrackMatcher.isGraphicalSubtitleCodec('sup'), isTrue);
    });

    test('uses expected codec hint when actual mpv codec is missing', () {
      expect(
        SubtitleTrackMatcher.classifyKind(
          codec: '',
          title: 'Styled signs',
          expectedCodec: 'ass',
        ),
        SubtitleKind.ass,
      );
    });

    test('matches the second bitmap track in a mixed subtitle list', () {
      final trackId = SubtitleTrackMatcher.matchTrackId(
        subtitleTracks: const [
          {
            'id': '11',
            'type': 'text',
            'title': 'English',
            'language': 'eng',
            'codec': 'srt',
          },
          {
            'id': '12',
            'type': 'bitmap',
            'title': 'Signs 1',
            'language': 'eng',
            'codec': 'hdmv_pgs_subtitle',
            'isBitmap': true,
          },
          {
            'id': '13',
            'type': 'text',
            'title': 'Commentary',
            'language': 'jpn',
            'codec': 'srt',
          },
          {
            'id': '14',
            'type': 'bitmap',
            'title': 'Signs 2',
            'language': 'jpn',
            'codec': 'hdmv_pgs_subtitle',
            'isBitmap': true,
          },
        ],
        targetKind: SubtitleKind.bitmap,
        targetStreamIndex: 9,
        typedStreamPosition: 1,
        targetLang: 'jpn',
        targetTitle: 'Signs 2',
        titlesMatch: titlesMatch,
      );

      expect(trackId, '14');
    });

    test('keeps ASS selection aligned when text and ASS are mixed', () {
      final trackId = SubtitleTrackMatcher.matchTrackId(
        subtitleTracks: const [
          {
            'id': '21',
            'type': 'text',
            'title': 'Plain text',
            'language': 'eng',
            'codec': 'srt',
          },
          {
            'id': '22',
            'type': 'text',
            'title': 'Styled overlay',
            'language': 'jpn',
            'codec': '',
          },
        ],
        targetKind: SubtitleKind.ass,
        targetStreamIndex: 7,
        typedStreamPosition: 1,
        targetLang: 'jpn',
        targetTitle: 'Styled overlay',
        titlesMatch: titlesMatch,
      );

      expect(trackId, '22');
    });
  });
}
