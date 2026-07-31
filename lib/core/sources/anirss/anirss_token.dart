import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

import '../../providers/server_providers.dart';
import '../media_source_backend.dart';
import '../source_http.dart';

/// Ani-rss 鉴权 + 请求生命周期（三端、播放后端与类型化 API 共享一份 token 缓存）。
///
/// 端点/字段以仓库根 `api-docs.json`（OpenAPI v3）为准，但**鉴权以服务端源码为准**
/// （ani-rss `AuthUtil`/`Header`/`Form`/`ApiKey`）：
/// - 登录 `POST /api/login`，body `{username, password(MD5摘要)}` → `ResultString`
///   （data=`sha256(json(login))` 登录令牌）。
/// - 校验该登录令牌的方式有二：① 请求头 **`Authorization: <token>`**（`Header` 鉴权）；
///   ② 查询参数 **`s=<token>`**（`Form` 鉴权，用于无法设请求头的流/图片 URL）。
///   swagger 里的 `api-key` 头是**另一套**「静态 Config.apiKey」鉴权，与登录令牌无关，
///   我们没有那个静态 key，故**绝不能**把登录令牌塞进 `api-key` 头（否则恒判失败→「登录已失效」）。
/// - 失效（服务端返回 `{code:403, message:'登录已失效'}`）→ 清缓存、用账密重登一次。
///
/// 单例：[AniRssAuth.instance]。`AniRssBackend`（播放路径）与 `AniRssApi`（浏览/订阅/
/// 设置）都依赖它，故任一路径触发的重登都会刷新另一路径使用的 token。
class AniRssAuth {
  AniRssAuth._();
  static final AniRssAuth instance = AniRssAuth._();

  /// 登录令牌的鉴权请求头名（服务端 `Header` 鉴权读 `Authorization`）。
  static const String header = 'Authorization';

  /// 登录令牌的查询参数名（服务端 `Form` 鉴权读 `s`；用于流/图片 URL）。
  static const String queryAuthKey = 's';

  final Map<String, String> _tokenCache = {};

  /// 密码按 swagger 要求取 MD5 摘要（32 位小写 hex）。
  static String md5(String password) =>
      crypto.md5.convert(utf8.encode(password)).toString();

  /// 账密登录拿令牌（静态，登录页/重新登录复用）。
  static Future<String> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    final dio = buildSourceDio(baseUrl: normalizeBaseUrl(baseUrl));
    final Response resp;
    try {
      resp = await dio.post('/api/login', data: {
        'username': username,
        'password': md5(password),
      });
    } catch (e) {
      throw SourceException('无法连接服务器: $e', cause: e);
    }
    final body = resp.data;
    if (body is! Map) throw SourceException('登录响应异常');
    if (body['code'] != 200) {
      throw SourceException(
        body['message']?.toString() ?? '登录失败',
        isAuth: true,
      );
    }
    final token = (body['data'] ?? '').toString();
    if (token.isEmpty) throw SourceException('登录未返回令牌', isAuth: true);
    return token;
  }

  /// 当前 token：优先内存缓存，回退 server.authToken；[force] 则强制重登。
  Future<String> ensureToken(ServerConfig server, {bool force = false}) async {
    if (!force) {
      final cached = _tokenCache[server.id] ?? server.authToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final u = server.username ?? '';
    final p = server.password ?? '';
    if (u.isEmpty) throw SourceException('登录已过期，请重新登录', isAuth: true);
    final token = await login(server.activeLineUrl, u, p);
    _tokenCache[server.id] = token;
    return token;
  }

  /// 清掉某服务器的 token 缓存（重新登录/移除服务器时调用）。
  void clearToken(String serverId) => _tokenCache.remove(serverId);

  /// 手动写入 token（如重新登录拿到新 token 后同步缓存）。
  void cacheToken(String serverId, String token) =>
      _tokenCache[serverId] = token;

  Dio _dio(ServerConfig server) =>
      buildSourceDio(baseUrl: normalizeBaseUrl(server.activeLineUrl));

  /// 发起一个带 `Authorization` 登录令牌头的鉴权请求；失效自动重登一次。
  /// [method] 默认 POST（ani-rss 绝大多数接口都是 POST）。
  Future<Response> authed(
    ServerConfig server,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String method = 'POST',
    bool retried = false,
  }) async {
    final token = await ensureToken(server, force: retried);
    final resp = await _dio(server).request(
      path,
      data: data,
      queryParameters: queryParameters,
      options: Options(method: method, headers: {header: token}),
    );
    final body = resp.data;
    final code = body is Map ? body['code'] : null;
    if ((code == 401 || code == 403) && !retried) {
      _tokenCache.remove(server.id);
      return authed(server, path,
          data: data,
          queryParameters: queryParameters,
          method: method,
          retried: true);
    }
    if (code != null && code != 200) {
      final msg = body is Map ? body['message']?.toString() : null;
      throw SourceException(msg ?? 'Ani-rss 请求失败（$code）',
          isAuth: code == 401 || code == 403);
    }
    return resp;
  }

  /// 解出标准返回包装体的 `data` 字段。
  dynamic unwrap(Response resp) {
    final body = resp.data;
    if (body is Map) return body['data'];
    return null;
  }
}
