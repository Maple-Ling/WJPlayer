import '../../core/api/api_interfaces.dart';
import 'persistent_json_cache.dart';

/// 服务器隔离的首页数据本地缓存服务。
///
/// 针对每个服务器独立缓存，避免服务器切换时数据污染。
/// 缓存键格式: "home_${serverId}_${dataType}"
/// - libraries: 媒体库列表
/// - resume: 继续观看
/// - random: 随机推荐
/// - collections: 合集
/// - latest:{libraryId}: 指定媒体库最新项目
/// - counts: 媒体统计
class HomeDataCache {
  static const Duration _defaultMaxAge = Duration(hours: 24);

  /// 读取缓存（如果存在且未过期）。
  static Future<T?> get<T>({
    required String serverId,
    required String dataType,
    required T Function(dynamic json) decode,
  }) async {
    final key = _cacheKey(serverId, dataType);
    final cached = await PersistentJsonCache.read(key);
    if (cached == null) return null;

    final savedAt = cached['savedAt'] as String?;
    if (savedAt != null) {
      final age = DateTime.now().difference(DateTime.parse(savedAt));
      if (age > _defaultMaxAge) return null;
    }

    final value = cached['value'];
    if (value == null) return null;
    try {
      return decode(value);
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存。
  static Future<void> set({
    required String serverId,
    required String dataType,
    required Object value,
  }) async {
    final key = _cacheKey(serverId, dataType);
    await PersistentJsonCache.write(key, value);
  }

  /// 失效指定类型缓存。
  static Future<void> invalidate(String serverId, String dataType) async {
    final key = _cacheKey(serverId, dataType);
    // 通过写入 null 来删除（PersistentJsonCache 不直接暴露 delete，但可写入空值标记）
    // 这里直接删除文件
    await _deleteKey(key);
  }

  /// 失效服务器所有首页缓存（含动态 latest:<libraryId> 预览键）。
  static Future<void> invalidateAll(String serverId) async {
    await PersistentJsonCache.deleteByPrefix('home_${serverId}_');
  }

  static String _cacheKey(String serverId, String dataType) =>
      'home_${serverId}_$dataType';

  static Future<void> _deleteKey(String key) => PersistentJsonCache.delete(key);
}

/// 统一的缓存优先数据加载器。
///
/// 用法：
/// final result = await HomeCacheLoader.load(
///   serverId: server.id,
///   dataType: 'libraries',
///   decode: (json) => (json as List).map((e) => Library.fromJson(e)).toList(),
///   load: () => ref.read(apiClientProvider).home.getLibraries(),
/// );
class HomeCacheLoader {
  static Future<T> load<T>({
    required String serverId,
    required String dataType,
    required T Function(dynamic json) decode,
    required Future<T> Function() load,
    Object Function(T value)? encode,
    Duration? maxAge,
    bool forceRefresh = false,
  }) async {
    // 1. 尝试读取缓存（手动刷新/错误重试时 forceRefresh 跳过缓存直接请求，
    //    否则网络故障期间缓存了空结果会一直显示空、点重试无反应）。
    if (!forceRefresh) {
      final cached = await HomeDataCache.get<T>(
        serverId: serverId,
        dataType: dataType,
        decode: decode,
      );
      if (cached != null) return cached;
    }

    // 2. 缓存未命中：网络请求
    final value = await load();

    // 3. 写入缓存（空结果不缓存：避免 24h 内一直显示空列表）。
    final isEmpty = value is List
        ? value.isEmpty
        : value is Map
            ? value.isEmpty
            : value == null;
    if (!isEmpty) {
      await HomeDataCache.set(
        serverId: serverId,
        dataType: dataType,
        value: encode == null ? _encode(value) : encode(value),
      );
    }

    return value;
  }

  static dynamic _encode(dynamic value) {
    if (value is List) {
      return value.map(_encode).toList();
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _encode(v)));
    }
    return value;
  }
}