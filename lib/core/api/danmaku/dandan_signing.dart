import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// 弹弹Play 开放平台签名器（弹幕 + 排行榜共用）。
///
/// 凭据仅编译期注入（Action 环境变量 DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET，
/// 二者均可多行/逗号/分号分隔，按行配对以分摊调用配额）。普通用户无凭据、也不手填。
/// 签名按官方文档：`X-Signature = Base64(SHA256(AppId + Timestamp + Path + AppSecret))`。
class DandanSigner {
  final List<({String appId, String secret})> credentials;
  static final _random = Random();

  const DandanSigner(this.credentials);

  factory DandanSigner.fromRaw(String appIdRaw, String secretRaw) =>
      DandanSigner(buildCredentials(appIdRaw, secretRaw));

  /// 从编译期环境变量构造（DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET）。
  factory DandanSigner.fromEnvironment() => DandanSigner.fromRaw(
        const String.fromEnvironment('DANDANPLAY_APP_ID', defaultValue: ''),
        const String.fromEnvironment('DANDANPLAY_APP_SECRET', defaultValue: ''),
      );

  bool get hasCredentials => credentials.isNotEmpty;

  // 兼容多种分隔：换行/逗号/分号（CI 可能把多行凭据合成逗号分隔）。
  static List<String> _lines(String v) => v
      .split(RegExp(r'[\n,;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static List<({String appId, String secret})> buildCredentials(
      String appIdRaw, String secretRaw) {
    final ids = _lines(appIdRaw);
    final secrets = _lines(secretRaw);
    if (ids.isEmpty || secrets.isEmpty) return const [];
    // 多对凭据按行配对；只有一个 AppId 时与每个 Secret 配对（兼容单 App 多 Secret）。
    if (ids.length == 1) {
      return [for (final s in secrets) (appId: ids.first, secret: s)];
    }
    final n = ids.length < secrets.length ? ids.length : secrets.length;
    return [for (var i = 0; i < n; i++) (appId: ids[i], secret: secrets[i])];
  }

  static String signature(
      String appId, String path, int timestamp, String secret) {
    final data = '$appId$timestamp$path$secret';
    return base64.encode(sha256.convert(utf8.encode(data)).bytes);
  }

  /// 为 [path]（形如 `/api/v2/...`，不含 query）生成带签名头的请求 Options。
  /// 无凭据时返回空 Options（请求会 401，由调用方按 success 字段判失败）。
  Options authOptions(String path) {
    if (credentials.isEmpty) return Options();
    final cred = credentials[_random.nextInt(credentials.length)];
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Options(headers: {
      'X-AppId': cred.appId,
      'X-Timestamp': timestamp.toString(),
      'X-Signature': signature(cred.appId, path, timestamp, cred.secret),
    });
  }
}
