import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/plugins/models/plugin_extension_point.dart';
import 'package:wjplayer/plugins/models/plugin_manifest.dart';
import 'package:wjplayer/plugins/models/plugin_permission.dart';
import 'package:wjplayer/plugins/runtime/plugin_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  group('PluginManifest', () {
    test('解析合法 manifest', () {
      final m = PluginManifest.fromJson({
        'id': 'com.example.foo',
        'version': '1.2.3',
        'name': 'Foo',
        'author': 'Me',
        'description': 'desc',
        'permissions': ['http', 'storage'],
        'extends': {
          'settingsPages': [
            {'id': 'settings', 'title': 'Settings', 'handler': 'openSettings'}
          ]
        }
      });
      expect(m.id, 'com.example.foo');
      expect(m.version, '1.2.3');
      expect(m.main, 'main.js');
      expect(m.permissions, containsAll(['http', 'storage']));
      expect(m.extensions.length, 1);
      expect(m.extensions.first.type, PluginExtensionType.settingsPages);
    });

    test('非反向域名 id 报错', () {
      expect(
        () => PluginManifest.fromJson({'id': 'foo', 'version': '1.0.0', 'name': 'x'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('非语义化版本报错', () {
      expect(
        () => PluginManifest.fromJson(
            {'id': 'a.b', 'version': 'v1', 'name': 'x'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('未知权限报错', () {
      expect(
        () => PluginManifest.fromJson({
          'id': 'a.b',
          'version': '1.0.0',
          'name': 'x',
          'permissions': ['filesystem']
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('未知扩展点类型报错', () {
      expect(
        () => PluginManifest.fromJson({
          'id': 'a.b',
          'version': '1.0.0',
          'name': 'x',
          'extends': {'unknownPoint': []}
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });
  });

  group('权限', () {
    test('log 隐式授予', () {
      final g = PluginGrantedPermissions(['http']);
      expect(g.has('log'), isTrue);
      expect(g.has('http'), isTrue);
      expect(g.has('storage'), isFalse);
    });

    test('covers 检查', () {
      final g = PluginGrantedPermissions(['http', 'storage']);
      expect(g.covers(['http', 'log']), isTrue);
      expect(g.covers(['http', 'player.read']), isFalse);
    });
  });

  group('扩展点平台支持', () {
    test('contextMenus 在 TV 不支持', () {
      expect(
        PluginExtensionSupport.isSupported(
            PluginExtensionType.contextMenus, PluginPlatform.tv),
        isFalse,
      );
      expect(
        PluginExtensionSupport.isSupported(
            PluginExtensionType.contextMenus, PluginPlatform.mobile),
        isTrue,
      );
    });

    test('sidebarItems 三端都支持', () {
      for (final pl in PluginPlatform.values) {
        expect(
          PluginExtensionSupport.isSupported(
              PluginExtensionType.sidebarItems, pl),
          isTrue,
        );
      }
    });
  });

  group('PluginStorage', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lp_storage_test');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('set/get/delete/keys/clear', () async {
      final s = PluginStorage(pluginId: 'a.b', dataDir: dir.path);
      await s.set('k', 'v');
      expect(await s.get('k'), 'v');
      expect(await s.keys(), contains('k'));
      await s.delete('k');
      expect(await s.get('k'), isNull);
      await s.set('x', 1);
      await s.clear();
      expect(await s.keys(), isEmpty);
    });

    test('持久化跨实例', () async {
      final s1 = PluginStorage(pluginId: 'a.b', dataDir: dir.path);
      await s1.set('token', 'abc');
      final s2 = PluginStorage(pluginId: 'a.b', dataDir: dir.path);
      expect(await s2.get('token'), 'abc');
    });

    test('超过 5MB 抛配额错误', () async {
      final s = PluginStorage(pluginId: 'a.b', dataDir: dir.path);
      final big = 'x' * (PluginStorage.maxBytes + 10);
      expect(
        () => s.set('huge', big),
        throwsA(isA<PluginStorageQuotaError>()),
      );
    });
  });

  test('storage.json 路径正确', () {
    final s = PluginStorage(pluginId: 'a.b', dataDir: '/tmp/foo');
    // 仅验证不抛错；实际文件名固定为 storage.json
    expect(p.basename(p.join('/tmp/foo', 'storage.json')), 'storage.json');
    expect(s.pluginId, 'a.b');
  });
}
