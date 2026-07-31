import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/app_identity.dart';
import 'package:wjplayer/core/providers/server_providers.dart';
import 'package:wjplayer/core/sources/feiniu_backend.dart';
import 'package:wjplayer/core/sources/source_kind.dart';

void main() {
  group('Emby 557 protocol compatibility', () {
    test('keeps upstream client identity used by protected media streams', () {
      expect(kEmbyProtocolClient, 'LinPlayer');
      expect(kEmbyProtocolDeviceId, 'linplayer-mobile');
      expect(kAppUserAgent, startsWith('LinPlayer/'));
      expect(kPreloadUserAgent, startsWith('LinplayerPreload/'));
    });
  });

  group('Feiniu media protocol', () {
    final server = ServerConfig(
      id: 'fn-test',
      name: '飞牛影视',
      baseUrl: 'http://192.0.2.1:8056',
      authToken: 'test-token',
      sourceKind: SourceKind.feiniu,
    );
    final backend = FeiniuBackend();

    test('builds authenticated sys/img URL', () async {
      expect(
        backend.imageUrl(server, '/ab/cd/poster.webp', width: 640),
        'http://192.0.2.1:8056/v/api/v1/sys/img/ab/cd/poster.webp?w=640',
      );
      final headers = await backend.imageHeaders(server);
      expect(headers['Authorization'], 'test-token');
      expect(headers['Cookie'], 'mode=relay');
      expect(
        headers['Authx'],
        matches(RegExp(r'^nonce=\d{6}&timestamp=\d{13}&sign=[0-9a-f]{32}$')),
      );
    });
  });

  test('Media3 forwards authenticated source headers', () {
    final source = File(
      'android/app/src/main/kotlin/com/mapleling/wjplayer/ExoPlayerPlugin.kt',
    ).readAsStringSync();
    expect(source, contains('call.argument<Map<String, String>>("httpHeaders")'));
    expect(source, contains('setDefaultRequestProperties(httpHeaders)'));
    expect(source, contains('error.errorCodeName'));
    expect(source, contains('pendingEvents'));
    expect(
      source.indexOf('exoPlayer.addListener(instance)'),
      lessThan(source.indexOf('exoPlayer.prepare()')),
    );
  });

  test('Feiniu playback keeps resume and writeback protocol fields', () {
    final source = File('lib/core/sources/feiniu_backend.dart')
        .readAsStringSync();
    expect(source, contains("_authed(server, '/play/list')"));
    expect(source, contains("_authed(server, '/play/record'"));
    for (final field in [
      'item_guid',
      'media_guid',
      'video_guid',
      'audio_guid',
      'subtitle_guid',
      'resolution',
      'bitrate',
      'ts',
      'duration',
    ]) {
      expect(source, contains("'$field'"), reason: field);
    }
  });

  test('JNI exports follow the WJPlayer Android package', () {
    const expectedPrefix = 'Java_com_mapleling_wjplayer_';
    for (final path in [
      'android/app/src/main/cpp/linass_jni.cpp',
      'android/app/src/main/cpp/mpv_init_jni.cpp',
      'android/app/src/main/cpp/mpv_render_jni.cpp',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains(expectedPrefix), reason: path);
      expect(source, isNot(contains('Java_com_example_wjplayer_1mobile_')),
          reason: path);
    }
  });
}
