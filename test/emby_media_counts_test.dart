import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/emby_api.dart';

void main() {
  group('EmbyHomeApi.getMediaCounts', () {
    test('uses the stored userId when auth token is present', () async {
      final requests = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        requests.add(request.requestedUri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'MovieCount': 12,
          'EpisodeCount': 34,
          'ItemCount': 46,
        }));
        await request.response.close();
      });

      final client = EmbyApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authToken: 'token-123',
        userId: 'user-123',
      );

      final counts = await client.home.getMediaCounts();

      expect(counts.movieCount, 12);
      expect(counts.episodeCount, 34);
      expect(counts.itemCount, 46);
      expect(requests, hasLength(1));
      expect(requests.single.path, '/Items/Counts');
      expect(requests.single.queryParameters['UserId'], 'user-123');
    });

    test('falls back to Me when only auth token is available', () async {
      final requests = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        requests.add(request.requestedUri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'MovieCount': 1,
          'EpisodeCount': 2,
          'ItemCount': 3,
        }));
        await request.response.close();
      });

      final client = EmbyApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authToken: 'token-123',
      );

      final counts = await client.home.getMediaCounts();

      expect(counts.movieCount, 1);
      expect(counts.episodeCount, 2);
      expect(counts.itemCount, 3);
      expect(requests, hasLength(1));
      expect(requests.single.queryParameters['UserId'], 'Me');
    });
  });
}
