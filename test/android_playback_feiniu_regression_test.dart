import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/app_identity.dart';
import 'package:wjplayer/core/providers/server_providers.dart';
import 'package:wjplayer/core/sources/feiniu_backend.dart';
import 'package:wjplayer/core/sources/source_kind.dart';

void main() {
  group('Emby 557 protocol compatibility', () {
    test('keeps upstream UA used by protected media streams', () {
      // 客户端名跟随 UI 品牌：服务器后台「正在播放」设备名显示 WJPlayer。
      expect(kEmbyProtocolClient, 'WJPlayer');
      expect(kEmbyProtocolDeviceId, 'wjplayer-mobile');
      // User-Agent 保持上游 LinPlayer 兼容标识：部分服务端/反代
      // 按 UA 白名单放行流媒体请求（后台不展示 UA，改名会破坏兼容）。
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
    expect(source, contains('setConnectTimeoutMs(30_000)'));
    expect(source, contains('setReadTimeoutMs(30_000)'));
    expect(source, contains('setLoadControl(loadControl)'));
    expect(
      source.indexOf('exoPlayer.addListener(instance)'),
      lessThan(source.indexOf('exoPlayer.prepare()')),
    );
  });

  test('Android permits authenticated LAN HTTP media servers', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final config = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:usesCleartextTraffic="true"'));
    expect(manifest, contains('@xml/network_security_config'));
    expect(config, contains('cleartextTrafficPermitted="true"'));
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

  test('Emby and Feiniu share the Feiniu-standard business UI', () {
    final router = File('lib/routes/app_router.dart').readAsStringSync();
    final unifiedUi = File(
      'lib/ui/screens/source/unified_media_screens.dart',
    ).readAsStringSync();
    final adapter = File(
      'lib/core/sources/unified_media_adapter.dart',
    ).readAsStringSync();

    expect(router, contains('return const UnifiedMediaHomeScreen()'));
    expect(router, contains('UnifiedEmbyDetailRoute'));
    expect(router, isNot(contains('const FeiniuHomeScreen()')));
    expect(adapter, contains('class EmbyUnifiedMediaAdapter'));
    expect(adapter, contains('class FeiniuUnifiedMediaAdapter'));
    expect(unifiedUi, contains('class UnifiedMediaHomeScreen'));
    expect(unifiedUi, contains('class UnifiedMediaLibraryScreen'));
    expect(unifiedUi, contains('class UnifiedMediaDetailScreen'));
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
