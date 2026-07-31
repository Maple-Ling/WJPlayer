import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/services/external_player/mpv_ipc_bridge.dart';
import 'package:path/path.dart' as p;

void main() {
  group('MpvIpcBridge', () {
    test('builds a platform specific endpoint and cleans stale unix sockets',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('mpv-ipc-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      if (!Platform.isWindows) {
        final stalePath = p.join(tempDir.path, 'wjplayer-mpv-session-1.sock');
        await File(stalePath).writeAsString('stale');
      }

      final bridge = await MpvIpcBridge.create(
        sessionId: 'session-1',
        directoryResolver: () async => tempDir,
      );
      addTearDown(() => bridge.close());

      if (Platform.isWindows) {
        expect(bridge.endpoint, r'\\.\pipe\wjplayer-mpv-session-1');
        expect(bridge.socketPath, isNull);
      } else {
        expect(
          bridge.endpoint,
          p.join(tempDir.path, 'wjplayer-mpv-session-1.sock'),
        );
        expect(await File(bridge.endpoint).exists(), isFalse);
      }
    });

    test('decodes JSON IPC lines into maps', () {
      final message = MpvIpcBridge.decodeMessage(
        '{"event":"property-change","name":"time-pos","data":12.5}',
      );

      expect(message, isNotNull);
      expect(message!['event'], 'property-change');
      expect(message['name'], 'time-pos');
      expect(message['data'], 12.5);
      expect(MpvIpcBridge.decodeMessage('not-json'), isNull);
      expect(MpvIpcBridge.decodeMessage('["unexpected"]'), isNull);
    });
  });
}
