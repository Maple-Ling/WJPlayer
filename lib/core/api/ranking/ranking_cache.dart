import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../services/cache_service.dart';
import 'ranking_models.dart';

/// 排行榜缓存：内存 + 磁盘 JSON。
///
/// key = 分类 id（如 `anime_hot_week`）。榜单变动不频繁，TTL 6 小时，
/// 命中即秒载，避免每次进页面都打网络。磁盘目录走项目统一缓存根。
class RankingCache {
  RankingCache._();
  static final RankingCache instance = RankingCache._();

  static const Duration _ttl = Duration(hours: 6);

  final Map<String, List<RankingEntry>> _mem = <String, List<RankingEntry>>{};
  String? _dirCache;

  String _fileNameOf(String key) =>
      '${md5.convert(utf8.encode(key))}.json';

  Future<String> _dirPath() async {
    if (_dirCache != null) return _dirCache!;
    final root = await CacheService.cacheRootDirPath;
    final dir = p.join(root, 'ranking_cache');
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
    _dirCache = dir;
    return dir;
  }

  /// 读取缓存。未命中 / 过期返回 null。
  Future<List<RankingEntry>?> get(String key) async {
    if (key.isEmpty) return null;
    final cached = _mem[key];
    if (cached != null) return cached;
    try {
      final file = File(p.join(await _dirPath(), _fileNameOf(key)));
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _ttl.inMilliseconds) {
        unawaited(file.delete().catchError((_) => file));
        return null;
      }
      final items = (raw['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RankingEntry.fromJson)
          .toList();
      if (items.isEmpty) return null;
      _mem[key] = items;
      return items;
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存（内存 + 磁盘）。空列表不写。
  Future<void> put(String key, List<RankingEntry> items) async {
    if (key.isEmpty || items.isEmpty) return;
    _mem[key] = items;
    try {
      final file = File(p.join(await _dirPath(), _fileNameOf(key)));
      await file.writeAsString(jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'items': items.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {
      // 磁盘写失败不影响内存缓存与本次浏览。
    }
  }

  /// 清空全部排行榜缓存（内存 + 磁盘）。返回删除的文件数。
  Future<int> clear() async {
    _mem.clear();
    try {
      final dir = Directory(await _dirPath());
      if (!await dir.exists()) return 0;
      var count = 0;
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          await e.delete();
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}
