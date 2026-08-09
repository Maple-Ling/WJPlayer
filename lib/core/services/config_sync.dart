// lib/core/services/config_sync.dart
// 局域网配置同步：二维码承载会话信息（TV 的 IP/端口/一次性 token），
// 配置本体走 HTTP 全量传输——服务器列表（CommonConfig AES 加密）+ 弹幕源
// 配置，无二维码容量限制（100+ 服务器轻松传输）。
//
// 流程：
//   TV（接收端）：启动本地 HttpServer + 生成 token → 显示二维码（会话信息）
//   手机（发送端）：扫码 → 解析 TV 地址 → 收集本机配置 → POST /sync → TV 应用
//
// 二维码内容: LPSYNC2:<base64url(json{ip, port, token})>（约 100 字符）
// POST body : json{v:2, token, servers:<ConfigTransfer.encode 输出>, danmaku:<JSON>}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 同步结果（接收/发送共用）。
class ConfigSyncResult {
  const ConfigSyncResult({
    required this.ok,
    this.serverCount = 0,
    this.danmakuCount = 0,
    this.error,
  });

  final bool ok;
  final int serverCount;
  final int danmakuCount;
  final String? error;

  factory ConfigSyncResult.fromMap(Map<String, dynamic> json) =>
      ConfigSyncResult(
        ok: json['ok'] == true,
        serverCount: (json['serverCount'] as num?)?.toInt() ?? 0,
        danmakuCount: (json['danmakuCount'] as num?)?.toInt() ?? 0,
        error: json['error']?.toString(),
      );

  Map<String, dynamic> toMap() => {
        'ok': ok,
        'serverCount': serverCount,
        'danmakuCount': danmakuCount,
        if (error != null) 'error': error,
      };
}

class ConfigSyncService {
  ConfigSyncService._();

  static const String qrPrefix = 'LPSYNC2:';
  static const String _danmakuPrefsKey = 'danmaku_custom_sources';

  // ─── 二维码会话信息编解码 ───

  static String encodeSession({required String ip, required int port, required String token}) {
    final payload = utf8.encode(jsonEncode({'ip': ip, 'port': port, 'token': token}));
    return qrPrefix + base64Url.encode(payload);
  }

  static Map<String, dynamic> decodeSession(String raw) {
    final s = raw.trim();
    if (!s.startsWith(qrPrefix)) {
      throw const FormatException('不是 WJPlayer 局域网同步二维码');
    }
    final jsonStr = utf8.decode(base64Url.decode(s.substring(qrPrefix.length)));
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final ip = map['ip']?.toString();
    final port = (map['port'] as num?)?.toInt();
    final token = map['token']?.toString();
    if (ip == null || ip.isEmpty || port == null || token == null || token.isEmpty) {
      throw const FormatException('同步二维码信息不完整');
    }
    return {'ip': ip, 'port': port, 'token': token};
  }

  /// 本机局域网 IPv4（优先 192.168/10./172.16-31 私网段）。
  static Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.') && _isPrivate172(ip)) {
            return ip;
          }
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isPrivate172(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]) ?? -1;
    return second >= 16 && second <= 31;
  }

  static String _randomToken() {
    final rng = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ─── TV 接收端：本地 HTTP 服务器 ───

  static HttpServer? _server;
  static String? _token;
  static StreamController<ConfigSyncResult>? _resultController;
  static Future<void> Function(List<Object?> servers, String? danmakuJson)? onReceive;

  /// 启动接收服务器，返回二维码内容。页面 dispose 前调用 [stopReceiver]。
  static Future<String> startReceiver() async {
    await stopReceiver();
    _token = _randomToken();
    _resultController = StreamController<ConfigSyncResult>.broadcast();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handleRequest, onError: (_) {});
    final ip = await localIp() ?? '127.0.0.1';
    return encodeSession(ip: ip, port: _server!.port, token: _token!);
  }

  static Stream<ConfigSyncResult> get results =>
      _resultController?.stream ?? const Stream<ConfigSyncResult>.empty();

  static Future<void> stopReceiver() async {
    _token = null;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
    await _resultController?.close();
    _resultController = null;
  }

  static void _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/sync') {
        final body = await utf8.decodeStream(request);
        final payload = jsonDecode(body) as Map<String, dynamic>;
        // 一次性 token 校验。
        if (_token == null || payload['token']?.toString() != _token) {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.write(jsonEncode({'ok': false, 'error': 'token 无效或已过期'}));
          await request.response.close();
          return;
        }
        // 解析服务器列表（CommonConfig 加密容器）。
        final serversStr = payload['servers']?.toString() ?? '';
        if (serversStr.isEmpty) {
          throw const FormatException('载荷缺少服务器数据');
        }
        final servers = await ConfigTransfer.decode(serversStr);
        final danmakuJson = payload['danmaku']?.toString();
        // 应用回调（页面注入：写服务器列表 + 弹幕源配置）。
        if (onReceive != null) {
          await onReceive!(servers.cast<Object?>(), danmakuJson);
        }
        // 成功后作废 token：只允许一次同步。
        final token = _token;
        _token = null;
        request.response.statusCode = HttpStatus.ok;
        request.response.write(jsonEncode({
          'ok': true,
          'serverCount': servers.length,
          'danmakuCount': _countDanmaku(danmakuJson),
        }));
        await request.response.close();
        // 通知页面刷新状态。
        _resultController?.add(ConfigSyncResult(
          ok: true,
          serverCount: servers.length,
          danmakuCount: _countDanmaku(danmakuJson),
        ));
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'ok': false, 'error': 'not found'}));
      await request.response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'ok': false, 'error': e.toString()}));
        await request.response.close();
      } catch (_) {}
      _resultController?.add(ConfigSyncResult(ok: false, error: e.toString()));
    }
  }

  static int _countDanmaku(String? json) {
    if (json == null || json.isEmpty) return 0;
    try {
      final list = jsonDecode(json);
      return list is List ? list.length : 0;
    } catch (_) {
      return 0;
    }
  }

  // ─── 手机发送端：扫码后推送 ───

  /// 解析二维码 → 收集配置 → POST 到 TV。返回同步结果。
  /// [collectServers] 由页面注入（返回本机服务器列表 JSON 字符串，
  /// 即 ConfigTransfer.encode 的输出）；[danmakuJson] 为弹幕源配置 JSON。
  static Future<ConfigSyncResult> sendToTv(
    String qrContent, {
    required Future<String> Function() collectServers,
    required Future<String?> Function() collectDanmaku,
  }) async {
    final info = decodeSession(qrContent);
    final serversStr = await collectServers();
    final danmakuJson = await collectDanmaku();
    final body = jsonEncode({
      'v': 2,
      'token': info['token'],
      'servers': serversStr,
      'danmaku': danmakuJson ?? '',
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .postUrl(Uri.parse('http://${info['ip']}:${info['port']}/sync'))
          .timeout(const Duration(seconds: 8));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final text = await utf8.decodeStream(resp);
      if (resp.statusCode != HttpStatus.ok) {
        Map<String, dynamic>? err;
        try {
          err = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        return ConfigSyncResult(
          ok: false,
          error: err?['error']?.toString() ?? '服务器返回 ${resp.statusCode}',
        );
      }
      return ConfigSyncResult.fromMap(jsonDecode(text) as Map<String, dynamic>);
    } catch (e) {
      return ConfigSyncResult(ok: false, error: '连接 TV 失败: $e');
    } finally {
      client.close(force: true);
    }
  }
}
