import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 外部影视资料的永久磁盘缓存。
///
/// 文件位于 Application Support，而不是系统临时缓存目录；不会按时间过期，
/// 网络失败时允许读取任意旧数据。仅 [clear]、卸载或清除 App 数据会删除。
class PersistentJsonCache {
  PersistentJsonCache._();

  static String? _root;

  static Future<String> get root async {
    if (_root != null) return _root!;
    final support = await getApplicationSupportDirectory();
    final value = path.join(support.path, 'external_media_cache_v1');
    await Directory(value).create(recursive: true);
    return _root = value;
  }

  static String _fileName(String key) => '${sha256.convert(utf8.encode(key))}.json';

  static Future<Map<String, dynamic>?> read(String key) async {
    try {
      final file = File(path.join(await root, _fileName(key)));
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, Object value) async {
    final target = File(path.join(await root, _fileName(key)));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode({
      'key': key,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'value': value,
    }), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static Future<dynamic> readValue(String key) async => (await read(key))?['value'];

  static Future<void> delete(String key) async {
    try {
      final file = File(path.join(await root, _fileName(key)));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 启动展示优先命中永久缓存；没有缓存才访问网络。
  static Future<T> cacheFirst<T>({
    required String key,
    required Future<T> Function() load,
    required T Function(dynamic value) decode,
  }) async {
    final cached = await readValue(key);
    if (cached != null) return decode(cached);
    return load();
  }

  /// 先尝试网络；成功即永久落盘。网络失败时回退旧缓存。
  static Future<T> networkFirst<T>({
    required String key,
    required Future<T> Function() load,
    required Object Function(T value) encode,
    required T Function(dynamic value) decode,
  }) async {
    try {
      final value = await load();
      await write(key, encode(value));
      return value;
    } catch (_) {
      final cached = await readValue(key);
      if (cached != null) return decode(cached);
      rethrow;
    }
  }

  static Future<int> size() async {
    final directory = Directory(await root);
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  static Future<void> clear() async {
    final directory = Directory(await root);
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
  }
}
