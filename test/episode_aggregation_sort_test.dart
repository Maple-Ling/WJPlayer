import 'package:flutter_test/flutter_test.dart';

import 'package:wjplayer/core/api/api_interfaces.dart';
import 'package:wjplayer/core/providers/episode_aggregation_provider.dart';
import 'package:wjplayer/core/providers/server_providers.dart';

AggregatedVersion _v(
  String serverId, {
  required bool matchesRegex,
  int width = 1920,
  int height = 1080,
}) {
  final server = ServerConfig(id: serverId, name: serverId, baseUrl: 'http://x');
  final item = MediaItem(id: 'i-$serverId', name: 'ep', type: 'Episode');
  final source = MediaSource(
    id: 's-$serverId-$width',
    mediaStreams: [
      MediaStream(index: 0, type: 'Video', width: width, height: height),
    ],
  );
  return AggregatedVersion(
    server: server,
    item: item,
    source: source,
    matchesRegex: matchesRegex,
  );
}

void main() {
  group('sortAggregatedVersions', () {
    test('正则命中的版本永远排在未命中之前', () {
      final list = [
        _v('a', matchesRegex: false),
        _v('b', matchesRegex: true),
      ];
      sortAggregatedVersions(list, {'a': 0, 'b': 1});
      expect(list.first.matchesRegex, isTrue);
      expect(list.first.server.id, 'b');
    });

    test('命中相同时按服务器顺序，同服内清晰度降序', () {
      final list = [
        _v('b', matchesRegex: false, width: 3840, height: 2160),
        _v('a', matchesRegex: false, width: 1280, height: 720),
        _v('a', matchesRegex: false, width: 3840, height: 2160),
      ];
      sortAggregatedVersions(list, {'a': 0, 'b': 1});
      // 服务器 a 先于 b；a 内 4K 先于 720p。
      expect(list.map((e) => e.server.id).toList(), ['a', 'a', 'b']);
      expect(list[0].source.qualityLabel, '4K');
      expect(list[1].source.qualityLabel, '720p');
    });

    test('正则优先高于清晰度：命中的 720p 排在未命中的 4K 之前', () {
      final list = [
        _v('a', matchesRegex: false, width: 3840, height: 2160),
        _v('a', matchesRegex: true, width: 1280, height: 720),
      ];
      sortAggregatedVersions(list, {'a': 0});
      expect(list.first.matchesRegex, isTrue);
    });
  });
}
