import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_identity.dart';

/// 服务器图标本地化：把**网络图标**下载落盘到 `应用支持目录/server_icons/`，返回稳定
/// 本地路径（失败返回 null）。用户选网络图标、以及首启时对自动图标一次性物化都复用它，
/// 让网络图标享受本地图标一样的离线持久——之后每次启动直接 `Image.file`，不再重拉/重试。
class ServerIconCache {
  ServerIconCache._();

  /// 一个字符串是否为本地图片路径（而非 http/https 网络地址）。
  static bool isLocalPath(String? url) =>
      url != null && url.isNotEmpty && !url.startsWith('http');

  /// 下载 [url] 到本地并返回路径；同服旧图会被清掉。失败返回 null（调用方保持原样）。
  static Future<String?> persist({
    required String serverId,
    required String url,
  }) async {
    if (!url.startsWith('http')) return url; // 已是本地路径，原样返回
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'server_icons'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      var ext = p.extension(Uri.parse(url).path).toLowerCase();
      if (ext.isEmpty || ext.length > 5) ext = '.png';
      final dest = p.join(
        dir.path,
        '${serverId}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      final resp = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'User-Agent': kDefaultBrowserUserAgent},
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final data = resp.data;
      if (data == null || data.isEmpty) return null;
      await File(dest).writeAsBytes(data);
      // 清掉该服务器的旧图标文件，避免目录堆积。
      final prefix = '${serverId}_';
      for (final entity in dir.listSync()) {
        if (entity is File &&
            p.basename(entity.path).startsWith(prefix) &&
            entity.path != dest) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
      return dest;
    } catch (_) {
      return null;
    }
  }
}
