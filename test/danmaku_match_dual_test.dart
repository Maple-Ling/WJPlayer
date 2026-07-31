import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/api_interfaces.dart';
import 'package:wjplayer/core/api/danmaku/danmaku_service.dart';
import 'package:wjplayer/core/api/danmaku/danmaku_source.dart';
import 'package:wjplayer/core/utils/danmaku_matcher.dart';

/// 假源：可指定 searchEpisodes / match 各自返回，验证「文件识别 + 名字搜索」两路合并。
class _FakeSource extends DanmakuSource {
  @override
  final DanmakuSourceConfig config;
  final DanmakuSearchResult searchResult;
  final DanmakuMatchResult matchResult;

  _FakeSource(this.config,
      {required this.searchResult, required this.matchResult});

  @override
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async =>
      matchResult;

  @override
  Future<DanmakuSearchResult> searchAnime({required String keyword}) async =>
      DanmakuSearchResult(animes: const []);

  @override
  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  }) async =>
      searchResult;

  @override
  Future<DanmakuAnime> getBangumiDetails({required String bangumiId}) async =>
      throw UnimplementedError();

  @override
  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  }) async =>
      const [];
}

class _FakeService extends DanmakuService {
  final List<DanmakuSource> srcs;
  _FakeService(this.srcs);
  @override
  List<DanmakuSource> sourcesFor({bool allowOfficial = true}) => srcs;
}

DanmakuSourceConfig _cfg() => DanmakuSourceConfig(
      id: 'fake',
      type: DanmakuSourceType.custom,
      name: '假源',
      apiUrl: 'https://x',
    );

MediaItem _ep() => MediaItem(
      id: '1',
      name: 'E01',
      type: 'Episode',
      seriesName: '关键词剧',
      indexNumber: 1,
      path: '/media/关键词剧/Season 1/关键词剧 - S01E01.mkv',
    );

void main() {
  test('两路合并：文件识别唯一命中排在名字搜索前', () async {
    final src = _FakeSource(
      _cfg(),
      searchResult: DanmakuSearchResult(animes: [
        DanmakuAnime(
          animeId: 'a1',
          animeTitle: '关键词剧',
          episodes: [
            DanmakuEpisode(
                episodeId: 'ep-search', episodeTitle: '第1话', episodeNumber: '1'),
          ],
        ),
      ]),
      matchResult: DanmakuMatchResult(isMatched: true, matches: [
        DanmakuMatchItem(
          episodeId: 'ep-file',
          animeId: 'a1',
          animeTitle: '关键词剧',
          episodeTitle: '第1话',
        ),
      ]),
    );
    final res = await DanmakuMatcher.matchAll(_FakeService([src]), _ep());
    expect(res.length, 2, reason: '文件识别 + 名字搜索各一条');
    expect(res.first.episodeId, 'ep-file', reason: '文件识别唯一命中最可信，排最前');
    expect(res.first.score, greaterThan(1.0));
  });

  test('同一集去重：两路返回同 episodeId 只留高分一条', () async {
    final src = _FakeSource(
      _cfg(),
      searchResult: DanmakuSearchResult(animes: [
        DanmakuAnime(
          animeId: 'a1',
          animeTitle: '关键词剧',
          episodes: [
            DanmakuEpisode(
                episodeId: 'same', episodeTitle: '第1话', episodeNumber: '1'),
          ],
        ),
      ]),
      matchResult: DanmakuMatchResult(isMatched: true, matches: [
        DanmakuMatchItem(
          episodeId: 'same',
          animeId: 'a1',
          animeTitle: '关键词剧',
          episodeTitle: '第1话',
        ),
      ]),
    );
    final res = await DanmakuMatcher.matchAll(_FakeService([src]), _ep());
    expect(res.length, 1, reason: '同 episodeId 去重');
    expect(res.first.score, greaterThan(1.0), reason: '保留文件识别的高分');
  });
}
