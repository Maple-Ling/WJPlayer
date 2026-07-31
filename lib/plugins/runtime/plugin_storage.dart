import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 每个插件独立的键值存储，持久化为插件数据目录下的 `storage.json`。
///
/// 约束：序列化后总大小上限 5MB，超过则 set 抛错（不写入）。
class PluginStorage {
  /// 5MB 上限。
  static const int maxBytes = 5 * 1024 * 1024;

  final String pluginId;
  final File _file;

  Map<String, dynamic> _data = {};
  bool _loaded = false;

  PluginStorage({required this.pluginId, required String dataDir})
      : _file = File(p.join(dataDir, 'storage.json'));

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      if (await _file.exists()) {
        final raw = await _file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) _data = decoded;
      }
    } catch (_) {
      _data = {};
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_data));
  }

  Future<dynamic> get(String key) async {
    await _ensureLoaded();
    return _data[key];
  }

  Future<List<String>> keys() async {
    await _ensureLoaded();
    return _data.keys.toList();
  }

  Future<void> set(String key, dynamic value) async {
    await _ensureLoaded();
    final next = Map<String, dynamic>.from(_data);
    next[key] = value;
    final encoded = jsonEncode(next);
    if (encoded.length > maxBytes) {
      throw PluginStorageQuotaError(pluginId, encoded.length);
    }
    _data = next;
    await _persist();
  }

  Future<void> delete(String key) async {
    await _ensureLoaded();
    if (_data.remove(key) != null) {
      await _persist();
    }
  }

  Future<void> clear() async {
    _data = {};
    _loaded = true;
    await _persist();
  }
}

/// 存储超出 5MB 配额。
class PluginStorageQuotaError implements Exception {
  final String pluginId;
  final int attemptedBytes;
  PluginStorageQuotaError(this.pluginId, this.attemptedBytes);
  @override
  String toString() =>
      'PluginStorageQuotaError: 插件 $pluginId 存储超出 5MB 上限（尝试写入 $attemptedBytes 字节）';
}
