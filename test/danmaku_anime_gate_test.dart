import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/api_interfaces.dart';
import 'package:wjplayer/core/api/danmaku/danmaku_service.dart';
import 'package:wjplayer/core/api/danmaku/danmaku_source.dart';
import 'package:wjplayer/core/utils/danmaku_matcher.dart';

MediaItem _item({
  String type = 'Movie',
  List<String>? genres,
  List<String>? tags,
  String? seriesId,
}) =>
    MediaItem(id: '1', name: 'x', type: type, genres: genres, tags: tags, seriesId: seriesId);

void main() {
  group('MediaItem.isAnime', () {
    test('动漫关键词命中（genres/tags，多语言）', () {
      expect(_item(genres: ['动画']).isAnime, isTrue);
      expect(_item(genres: ['Anime', 'Comedy']).isAnime, isTrue);
      expect(_item(tags: ['アニメ']).isAnime, isTrue);
      expect(_item(genres: ['Animation']).isAnime, isTrue);
    });

    test('非动漫（真人剧/电影）不命中', () {
      expect(_item(genres: ['Drama', 'Crime']).isAnime, isFalse);
      expect(_item(genres: [], tags: []).isAnime, isFalse);
      expect(_item().isAnime, isFalse);
    });
  });

  group('resolveIsAnime 剧集回退', () {
    test('剧集自身无 genres 时用 series 判定', () async {
      final ep = _item(type: 'Episode', seriesId: 's1');
      // series 是动漫
      expect(
        await DanmakuMatcher.resolveIsAnime(ep,
            fetchItem: (id) async => _item(genres: ['动画'])),
        isTrue,
      );
      // series 非动漫
      expect(
        await DanmakuMatcher.resolveIsAnime(ep,
            fetchItem: (id) async => _item(genres: ['Drama'])),
        isFalse,
      );
      // 无 fetchItem：只看自身 → false
      expect(await DanmakuMatcher.resolveIsAnime(ep), isFalse);
    });
  });

  group('DanmakuService.sourcesFor 官方源门控', () {
    late DanmakuService svc;
    setUp(() {
      svc = DanmakuService()
        ..initDandanplay(appId: 'app', appSecret: 'secret')
        ..addSource(DanmakuSourceConfig(
          id: 'custom1',
          type: DanmakuSourceType.custom,
          name: '自建源',
          apiUrl: 'https://example.com',
        ));
    });

    test('allowOfficial=true 含弹弹Play + 自定义', () {
      final ids = svc.sourcesFor(allowOfficial: true).map((s) => s.config.id);
      expect(ids, containsAll(<String>['dandanplay', 'custom1']));
    });

    test('allowOfficial=false 剔除弹弹Play、保留自定义', () {
      final ids = svc.sourcesFor(allowOfficial: false).map((s) => s.config.id).toList();
      expect(ids, isNot(contains('dandanplay')));
      expect(ids, contains('custom1'));
    });
  });
}
