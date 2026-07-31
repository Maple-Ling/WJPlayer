import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'source_http.dart';

/// 飞牛影视（trimemedia / fnOS 视频）后端。
///
/// 全媒体服务器（媒体库→电影/剧集→季→分集），但接进「文件浏览型源」这条线：
/// 媒体库/季当文件夹，电影/分集当可播文件。直连原文件走 Range 播放（保留内封
/// 音轨/字幕），交给现有播放层。
///
/// 接口：`{host}/v/api/v1/...`，账密 `POST /login` 拿 token 走 `Authorization`，
/// 每个请求另带 `authx` 签名头。端点/签名取自飞牛 PC 版（QiaoKes/fntv-electron）
/// 与 MoviePilot trimemedia 模块。
///
/// **注意**：直连 `media/range` 用的是「静态」authx（构造播放时算一次），若飞牛
/// 服务端对流请求校验签名时间戳，长片播到中途可能因签名过期而断——届时需改为本地
/// 重签代理（同 fntv-electron 的 127.0.0.1 代理做法）。首版按直连做，待真机验证。
// ponytail: 静态 authx；若长播断流，升级为本地重签代理（见类注释）。
class FeiniuBackend implements MediaSourceBackend {
  @override
  SourceKind get kind => SourceKind.feiniu;

  /// 签名常量（飞牛客户端硬编码，非用户密钥）。
  static const _signSecret = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
  static const _apiKey = '16CCEB3D-AB42-077D-36A1-F355324E4237';
  static const _apiPrefix = '/v/api/v1';

  final _rand = Random();

  /// 内存 token 缓存（serverId → token）。
  final Map<String, String> _tokenCache = {};

  Dio _dio(ServerConfig server) =>
      buildSourceDio(baseUrl: normalizeBaseUrl(server.activeLineUrl));

  /// 计算 authx 签名头。[path] 为带 `/v/api/v1` 前缀的 API 路径（不含 host），
  /// [body] 为实际发送的请求体字符串（GET 传空串）。
  String _authx(String path, String body) {
    final nonce = (100000 + _rand.nextInt(900000)).toString();
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final dataHash = md5.convert(utf8.encode(body)).toString();
    final sign = md5
        .convert(utf8.encode(
            [_signSecret, path, nonce, ts, dataHash, _apiKey].join('_')))
        .toString();
    return 'nonce=$nonce&timestamp=$ts&sign=$sign';
  }

  /// 账密登录拿 token。供登录页首次登录与自动重登复用。
  static Future<String> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    final backend = FeiniuBackend();
    final base = normalizeBaseUrl(baseUrl);
    final dio = buildSourceDio(baseUrl: base);
    const path = '$_apiPrefix/login';
    // 密码为明文（与飞牛 web/PC 客户端一致，无 RSA/MD5 预处理）。
    final body = jsonEncode({
      'app_name': 'trimemedia-web',
      'username': username,
      'password': password,
      'nonce': (100000 + backend._rand.nextInt(900000)).toString(),
    });
    final Response resp;
    try {
      resp = await dio.post(
        path,
        data: body,
        options: Options(headers: {
          'Content-Type': 'application/json',
          'Cookie': 'mode=relay',
          'authx': backend._authx(path, body),
        }),
      );
    } catch (e) {
      throw SourceException('无法连接飞牛服务器: $e', cause: e);
    }
    final data = _unwrap(resp.data, auth: true);
    final token = (data is Map ? data['token'] : null)?.toString() ?? '';
    if (token.isEmpty) throw SourceException('登录未返回 token', isAuth: true);
    return token;
  }

  Future<String> _ensureToken(ServerConfig server, {bool force = false}) async {
    if (!force) {
      final cached = _tokenCache[server.id] ?? server.authToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final u = server.username ?? '';
    if (u.isEmpty) throw SourceException('登录已过期，请重新登录', isAuth: true);
    final token = await login(server.activeLineUrl, u, server.password ?? '');
    _tokenCache[server.id] = token;
    return token;
  }

  /// 带鉴权请求。[suffix] 不含 `/v/api/v1` 前缀。非零 code 视作失败，首个错误自动
  /// 重登一次再试（飞牛不明确区分鉴权错误码，统一重登兜底）。
  Future<dynamic> _authed(
    ServerConfig server,
    String suffix, {
    Map<String, dynamic>? data,
    bool retried = false,
  }) async {
    final token = await _ensureToken(server, force: retried);
    final path = '$_apiPrefix$suffix';
    final isPost = data != null;
    final body = isPost
        ? jsonEncode({
            ...data,
            'nonce': (100000 + _rand.nextInt(900000)).toString(),
          })
        : '';
    final headers = <String, dynamic>{
      'Authorization': token,
      'Cookie': 'mode=relay',
      'authx': _authx(path, body),
    };
    if (isPost) headers['Content-Type'] = 'application/json';

    final Response resp;
    try {
      resp = isPost
          ? await _dio(server)
              .post(path, data: body, options: Options(headers: headers))
          : await _dio(server).get(path, options: Options(headers: headers));
    } catch (e) {
      throw SourceException('飞牛请求失败: $e', cause: e);
    }
    final map = resp.data;
    final code = map is Map ? (map['code'] as num?)?.toInt() : null;
    if (code != 0 && !retried) {
      _tokenCache.remove(server.id);
      return _authed(server, suffix, data: data, retried: true);
    }
    return _unwrap(map, auth: true);
  }

  /// 拆 `{code,msg,data}` 信封，非零抛异常。
  static dynamic _unwrap(dynamic body, {bool auth = false}) {
    if (body is! Map) throw SourceException('飞牛响应异常');
    final code = (body['code'] as num?)?.toInt();
    if (code != 0) {
      final msg = body['msg']?.toString() ?? '飞牛请求失败（$code）';
      throw SourceException(msg, isAuth: auth);
    }
    return body['data'];
  }

  @override
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId}) async {
    if (dirId == null || dirId.isEmpty) return _listLibraries(server);
    final sep = dirId.indexOf(':');
    final kind = sep < 0 ? '' : dirId.substring(0, sep);
    final guid = sep < 0 ? dirId : dirId.substring(sep + 1);
    switch (kind) {
      case 'tv':
        return _listSeasons(server, guid);
      case 'season':
        return _listEpisodes(server, guid);
      case 'lib':
      case 'dir':
      default:
        return _listItems(server, guid);
    }
  }

  Future<List<SourceEntry>> _listLibraries(ServerConfig server) async {
    // 普通用户端点，管理员账号同样可见其可访问的库。
    final data = await _authed(server, '/mediadb/list');
    final list = (data as List?) ?? const [];
    return list.map<SourceEntry>((e) {
      final m = e as Map;
      return SourceEntry(
        id: 'lib:${m['guid']}',
        name: (m['title'] ?? m['name'] ?? '未命名媒体库').toString(),
        isDir: true,
      );
    }).toList();
  }

  Future<List<SourceEntry>> _listItems(ServerConfig server, String guid) async {
    final data = await _authed(server, '/item/list', data: {
      'ancestor_guid': guid,
      'tags': {
        'type': ['Movie', 'TV', 'Directory', 'Video']
      },
      'exclude_grouped_video': 1,
      'sort_type': 'DESC',
      'sort_column': 'create_time',
      'page': 1,
      'page_size': 500,
    });
    final list = ((data as Map?)?['list'] as List?) ?? const [];
    return list.map<SourceEntry>(_itemToEntry).toList();
  }

  Future<List<SourceEntry>> _listSeasons(
      ServerConfig server, String tvGuid) async {
    final data = await _authed(server, '/season/list/$tvGuid');
    final list = (data as List?) ?? const [];
    return list.map<SourceEntry>((e) {
      final m = e as Map;
      final n = m['season_number'];
      return SourceEntry(
        id: 'season:${m['guid']}',
        name: (m['title']?.toString().isNotEmpty ?? false)
            ? m['title'].toString()
            : (n != null ? '第 $n 季' : '季'),
        isDir: true,
      );
    }).toList();
  }

  Future<List<SourceEntry>> _listEpisodes(
      ServerConfig server, String seasonGuid) async {
    final data = await _authed(server, '/episode/list/$seasonGuid');
    final list = (data as List?) ?? const [];
    return list.map<SourceEntry>(_itemToEntry).toList();
  }

  /// 单个 item → 目录（TV/季/Directory）或可播文件（电影/视频/分集）。
  SourceEntry _itemToEntry(dynamic e) {
    final m = e as Map;
    final guid = m['guid'].toString();
    final type = m['type']?.toString() ?? 'Video';
    switch (type) {
      case 'TV':
        return SourceEntry(id: 'tv:$guid', name: _title(m), isDir: true);
      case 'Directory':
        return SourceEntry(id: 'dir:$guid', name: _title(m), isDir: true);
      case 'Season':
        return SourceEntry(id: 'season:$guid', name: _title(m), isDir: true);
      default: // Movie / Video / Episode → 可播
        return SourceEntry(
          id: guid,
          name: _episodeTitle(m),
          isDir: false,
          isVideo: true,
          size: (m['file_size'] as num?)?.toInt(),
        );
    }
  }

  String _title(Map m) =>
      (m['title'] ?? m['original_title'] ?? '未命名').toString();

  /// 分集名带上季/集号，便于列表区分。
  String _episodeTitle(Map m) {
    final ep = m['episode_number'];
    final se = m['season_number'];
    final t = _title(m);
    if (m['type'] == 'Episode' && ep != null) {
      final prefix = se != null ? 'S${se}E$ep' : 'E$ep';
      return t.isEmpty || t == '未命名' ? prefix : '$prefix $t';
    }
    return t;
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) async {
    final data = await _authed(server, '/search/list?q=${Uri.encodeQueryComponent(query)}');
    final list = (data as List?) ?? const [];
    return list
        .map<SourceEntry>(_itemToEntry)
        .where((e) => !e.isDir || e.id.startsWith('tv:'))
        .toList();
  }

  @override
  Future<ResolvedPlay> resolvePlay(
    ServerConfig server,
    SourceEntry entry, {
    String? qualityId,
  }) async {
    final info = await _authed(server, '/play/info', data: {
      'item_guid': entry.id,
    });
    final mediaGuid = (info as Map?)?['media_guid']?.toString() ?? '';
    if (mediaGuid.isEmpty) throw SourceException('未获取到播放媒体');

    final token = _tokenCache[server.id] ?? server.authToken ?? '';
    final base = normalizeBaseUrl(server.activeLineUrl);
    final streamPath = '$_apiPrefix/media/range/$mediaGuid';
    final headers = {
      'Authorization': token,
      'Cookie': 'mode=relay',
      'authx': _authx(streamPath, ''),
    };

    return ResolvedPlay(
      url: '$base$streamPath',
      title: entry.name,
      httpHeaders: headers,
      subtitles: await _externalSubs(server, entry.id, base, token),
    );
  }

  /// 外挂字幕（内封音轨/字幕由 mpv 直接读原文件，这里只补服务端外挂字幕）。
  Future<List<SourceSubtitle>> _externalSubs(
      ServerConfig server, String itemGuid, String base, String token) async {
    try {
      final data = await _authed(server, '/stream/list/$itemGuid');
      final subs = ((data as Map?)?['subtitle_streams'] as List?) ?? const [];
      return subs
          .where((s) => (s as Map)['is_external'] == true)
          .map<SourceSubtitle>((s) {
        final m = s as Map;
        final subPath = '$_apiPrefix/subtitle/dl/${m['guid']}';
        return SourceSubtitle(
          url: '$base$subPath',
          title: m['title']?.toString(),
          language: m['language']?.toString(),
          httpHeaders: {
            'Authorization': token,
            'Cookie': 'mode=relay',
            'authx': _authx(subPath, ''),
          },
        );
      }).toList();
    } catch (_) {
      return const []; // 字幕拉取失败不影响正片播放。
    }
  }
}
