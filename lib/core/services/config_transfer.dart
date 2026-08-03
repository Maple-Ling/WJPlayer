import 'dart:convert';
import 'dart:io';

import '../providers/server_providers.dart';
import 'common_config.dart';

/// 设备间「扫码搬配置」的载荷编解码。
///
/// 复用 [CommonConfig] 把服务器(含 access_token/密码)AES 加密成通用配置容器,
/// 再 gzip + base64url 压进一个字符串塞进二维码——**全程离线**,不依赖任何网络/后端,
/// 局域网、跨网、断网都能扫。容量不足时上层回退到「备份与恢复」的文件导出。
class ConfigTransfer {
  ConfigTransfer._();

  /// 二维码前缀,用于扫码端识别是本 App 的配置载荷(而非随便一个二维码)。
  static const String _prefix = 'LPSYNC1:';

  /// 单个二维码可容纳的载荷上限(字符数)。取 QR 版本40/纠错M 的字节容量(2331),
  /// 尽量贴近物理上限以容纳更多设备/服务器;超过则上层提示改用文件备份。
  static const int maxQrChars = 2331;

  /// 把服务器列表编码成可放进二维码的字符串。
  static Future<String> encode(List<ServerConfig> servers) async {
    final container = await CommonConfig.build(
      servers,
      exportTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final jsonBytes = utf8.encode(jsonEncode(container));
    final gz = gzip.encode(jsonBytes);
    return _prefix + base64Url.encode(gz);
  }

  /// 解码扫到的字符串为服务器列表。非本 App 载荷或损坏时抛异常。
  static Future<List<ServerConfig>> decode(String raw) async {
    final s = raw.trim();
    if (!s.startsWith(_prefix)) {
      throw const FormatException('不是 WJPlayer 配置二维码');
    }
    final gz = base64Url.decode(s.substring(_prefix.length));
    final jsonStr = utf8.decode(gzip.decode(gz));
    final container = jsonDecode(jsonStr) as Map<String, dynamic>;
    return CommonConfig.parse(container);
  }

  /// 按 `id` 合并:导入项覆盖同 id 的旧项,其余保留,新项追加。
  /// CommonConfig 会原样带回服务器 id,所以同一服务器重复导入不会产生重复条目。
  static List<ServerConfig> merge(
    List<ServerConfig> existing,
    List<ServerConfig> incoming,
  ) {
    final incomingIds = incoming.map((s) => s.id).toSet();
    return [
      ...existing.where((s) => !incomingIds.contains(s.id)),
      ...incoming,
    ];
  }
}
