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
class FeiniuMediaCounts {
  const FeiniuMediaCounts({
    required this.movieCount,
    required this.seriesCount,
    required this.episodeCount,
  });

  final int movieCount;
  final int seriesCount;
  final int episodeCount;
}

class FeiniuItemDetail {
  final SourceEntry entry;
  final Map<String, dynamic> item;
  final Map<String, dynamic> playInfo;
  final List<SourceEntry> seasons;
  final String? seriesGuid;

  const FeiniuItemDetail({
    required this.entry,
    required this.item,
    required this.playInfo,
    this.seasons = const [],
    this.seriesGuid,
  });
}

class FeiniuContinueItem {
  final SourceEntry entry;
  final Duration position;
  final Duration duration;

  const FeiniuContinueItem({
    required this.entry,
    required this.position,
    required this.duration,
  });

  double get progress => duration.inMilliseconds <= 0
      ? 0.0
      : (position.inMilliseconds / duration.inMilliseconds)
          .clamp(0.0, 1.0)
          .toDouble();
}

class FeiniuMediaDetails {
  final Map<String, dynamic> playInfo;
  final Map<String, dynamic> stream;

  const FeiniuMediaDetails({
    required this.playInfo,
    required this.stream,
  });

  Map<String, dynamic>? get video => _map(stream['video_stream']);
  List<Map<String, dynamic>> get audios => _maps(stream['audio_streams']);
  List<Map<String, dynamic>> get subtitles =>
      _maps(stream['subtitle_streams']);
  Map<String, dynamic>? get file => _map(stream['file_stream']);

  static Map<String, dynamic>? _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : null;

  static List<Map<String, dynamic>> _maps(dynamic value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : const [];
}

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

  String imageUrl(ServerConfig server, String? posterPath, {int width = 480}) {
    final raw = posterPath?.trim() ?? '';
    if (raw.isEmpty) return '';
    final path = raw.startsWith('/') ? raw : '/$raw';
    final base = normalizeBaseUrl(server.activeLineUrl);
    return '$base$_apiPrefix/sys/img$path?w=$width';
  }

  Future<Map<String, String>> imageHeaders(ServerConfig server) async {
    final token = await _ensureToken(server);
    const signPath = '$_apiPrefix/sys/img';
    return {
      'Authorization': token,
      'Cookie': 'mode=relay',
      'Authx': _authx(signPath, ''),
    };
  }

  /// 飞牛不同接口的图片字段并不统一：媒体库通常为 poster，搜索/继续观看
  /// 可能是 poster_path / cover / image / still_path。统一归一后再经 sys/img 请求，
  /// 避免搜索卡片和详情页因字段名差异丢失封面。
  String? _posterOf(Map<dynamic, dynamic> item) {
    for (final key in const [
      'poster',
      'poster_path',
      'cover',
      'cover_path',
      'image',
      'image_path',
      'still_path',
      'thumb',
      'thumbnail',
    ]) {
      final value = item[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value != 'null') return value;
    }
    final posters = item['posters'];
    if (posters is List && posters.isNotEmpty) {
      final first = posters.first?.toString().trim() ?? '';
      if (first.isNotEmpty && first != 'null') return first;
    }
    return null;
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
    // 除登录外，普通 POST 请求体必须原样参与 Authx 计算；额外注入 nonce 会
    // 改变 play/info、item/list 等接口的参数和签名，导致详情或播放失败。
    final body = isPost ? jsonEncode(data) : '';
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
    final headers = await imageHeaders(server);
    return list.map<SourceEntry>((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return SourceEntry(
        id: 'lib:${m['guid']}',
        name: (m['title'] ?? m['name'] ?? '未命名媒体库').toString(),
        isDir: true,
        thumbUrl: imageUrl(server, _posterOf(m), width: 640),
        thumbHeaders: headers,
        raw: m,
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
    final headers = await imageHeaders(server);
    return list
        .map<SourceEntry>((e) => _itemToEntry(server, e, headers))
        .toList();
  }

  Future<List<SourceEntry>> _listSeasons(
      ServerConfig server, String tvGuid) async {
    final data = await _authed(server, '/season/list/$tvGuid');
    final list = (data as List?) ?? const [];
    final headers = await imageHeaders(server);
    final seasons = list.map<SourceEntry>((e) {
      final m = Map<String, dynamic>.from(e as Map);
      final n = m['season_number'];
      return SourceEntry(
        id: 'season:${m['guid']}',
        name: (m['title']?.toString().isNotEmpty ?? false)
            ? m['title'].toString()
            : (n != null ? '第 $n 季' : '季'),
        isDir: true,
        thumbUrl: imageUrl(server, _posterOf(m), width: 480),
        thumbHeaders: headers,
        raw: m,
      );
    }).toList();
    seasons.sort((a, b) =>
        ((a.raw?['season_number'] as num?)?.toInt() ?? 0).compareTo(
            (b.raw?['season_number'] as num?)?.toInt() ?? 0));
    return seasons;
  }

  Future<List<SourceEntry>> _listEpisodes(
      ServerConfig server, String seasonGuid) async {
    final data = await _authed(server, '/episode/list/$seasonGuid');
    final list = (data as List?) ?? const [];
    final headers = await imageHeaders(server);
    final episodes = list
        .map<SourceEntry>((e) => _itemToEntry(server, e, headers))
        .toList();
    episodes.sort((a, b) =>
        ((a.raw?['episode_number'] as num?)?.toInt() ?? 0).compareTo(
            (b.raw?['episode_number'] as num?)?.toInt() ?? 0));
    return episodes;
  }

  /// 单个 item → 媒体条目。只有真正的 Directory 继续按文件夹下钻；
  /// TV/Movie/Episode/Video 都进入媒体详情或播放流程。
  SourceEntry _itemToEntry(
    ServerConfig server,
    dynamic value,
    Map<String, String> headers,
  ) {
    final m = Map<String, dynamic>.from(value as Map);
    final guid = m['guid']?.toString() ?? '';
    final type = m['type']?.toString() ?? 'Video';
    final poster = _posterOf(m);
    if (type == 'Directory' || type == 'TV') {
      return SourceEntry(
        id: type == 'TV' ? 'tv:$guid' : 'dir:$guid',
        name: _title(m),
        isDir: true,
        thumbUrl: imageUrl(server, poster),
        thumbHeaders: headers,
        raw: m,
      );
    }
    return SourceEntry(
      id: guid,
      name: _episodeTitle(m),
      isDir: false,
      isVideo: type == 'Movie' || type == 'Video' || type == 'Episode',
      size: (m['file_size'] as num?)?.toInt(),
      thumbUrl: imageUrl(server, poster),
      thumbHeaders: headers,
      raw: m,
    );
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

  Future<List<SourceEntry>> libraries(ServerConfig server) =>
      _listLibraries(server);

  Future<List<SourceEntry>> libraryItems(
    ServerConfig server,
    String libraryId, {
    int pageSize = 100,
  }) {
    final guid = libraryId.startsWith('lib:')
        ? libraryId.substring(4)
        : libraryId;
    return _listItems(server, guid);
  }

  Future<FeiniuMediaCounts> mediaCounts(ServerConfig server) async {
    final libraries = await _listLibraries(server);
    var movie = 0;
    var series = 0;
    var episodes = 0;
    for (final library in libraries) {
      final guid = library.id.startsWith('lib:') ? library.id.substring(4) : library.id;
      movie += await _countType(server, guid, 'Movie');
      series += await _countType(server, guid, 'TV');
      episodes += await _countType(server, guid, 'Episode');
    }
    return FeiniuMediaCounts(movieCount: movie, seriesCount: series, episodeCount: episodes);
  }

  Future<int> _countType(ServerConfig server, String guid, String type) async {
    var page = 1;
    var counted = 0;
    while (page <= 100) {
      final data = await _authed(server, '/item/list', data: {
        'ancestor_guid': guid,
        'tags': {'type': [type]},
        'exclude_grouped_video': 1,
        'sort_type': 'DESC',
        'sort_column': 'create_time',
        'page': page,
        'page_size': 500,
      });
      final map = data is Map ? data : const <String, dynamic>{};
      final list = map['list'] is List ? map['list'] as List : const [];
      final total = _readTotal(map);
      if (total != null) return total;
      counted += list.length;
      if (list.length < 500) break;
      page++;
    }
    return counted;
  }

  int? _readTotal(Map<dynamic, dynamic> data) {
    for (final key in const ['total', 'total_count', 'count', 'totalCount']) {
      final value = data[key];
      if (value is num) return value.toInt();
    }
    return null;
  }

  Future<List<FeiniuContinueItem>> continueWatching(ServerConfig server) async {
    final data = await _authed(server, '/play/list');
    final list = data is List
        ? data
        : ((data as Map?)?['list'] as List? ?? const []);
    final headers = await imageHeaders(server);
    return list.map<FeiniuContinueItem?>((value) {
      if (value is! Map) return null;
      final m = Map<String, dynamic>.from(value);
      final guid = (m['guid'] ?? m['item_guid'] ?? m['itemId'])?.toString() ?? '';
      final duration = (m['duration'] as num?)?.toInt() ?? 0;
      final position = (m['ts'] ?? m['position'] ?? m['watched_ts']);
      final ts = position is num ? position.toInt() : 0;
      if (guid.isEmpty || duration <= 0 || ts <= 0 || ts >= duration * 0.95) {
        return null;
      }
      final episodeNumber = (m['episode_number'] as num?)?.toInt() ?? 0;
      final type = (m['type'] ?? (episodeNumber > 0 ? 'Episode' : 'Video'))
          .toString();
      final item = <String, dynamic>{
        ...m,
        'guid': guid,
        'type': type,
        'title': (m['title'] ?? m['name'] ?? '继续观看').toString(),
        'poster': m['poster'] ?? m['posters'] ?? m['still_path'],
      };
      return FeiniuContinueItem(
        entry: _itemToEntry(server, item, headers),
        position: Duration(seconds: ts),
        duration: Duration(seconds: duration),
      );
    }).whereType<FeiniuContinueItem>().toList();
  }

  Future<List<Map<String, dynamic>>> persons(
    ServerConfig server,
    String itemGuid,
  ) async {
    try {
      final data = await _authed(server, '/person/list/$itemGuid', data: {
        'page': 1,
        'page_size': 200,
      });
      final list = data is Map ? data['list'] : data;
      return list is List
          ? list.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : const [];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SourceEntry>> episodes(
    ServerConfig server,
    String seasonId,
  ) {
    final guid = seasonId.startsWith('season:')
        ? seasonId.substring(7)
        : seasonId;
    return _listEpisodes(server, guid);
  }

  Future<FeiniuItemDetail> itemDetail(
    ServerConfig server,
    SourceEntry entry,
  ) async {
    final guid = entry.id.contains(':')
        ? entry.id.substring(entry.id.indexOf(':') + 1)
        : entry.id;
    final results = await Future.wait<dynamic>([
      _authed(server, '/item/$guid'),
      _authed(server, '/play/info', data: {'item_guid': guid}),
    ]);
    final item = results[0] is Map
        ? Map<String, dynamic>.from(results[0] as Map)
        : <String, dynamic>{};
    final playInfo = results[1] is Map
        ? Map<String, dynamic>.from(results[1] as Map)
        : <String, dynamic>{};
    final entryType = entry.raw?['type']?.toString();
    final merged = <String, dynamic>{...item};
    final nested = playInfo['item'];
    // TV 的 play/info 常返回默认播放集，不能让该 Episode 覆盖剧集自身标题/海报；
    // Movie/Video/Episode 则可用 play/info.item 补齐简介、剧照等字段。
    if (nested is Map && entryType != 'TV') {
      merged.addAll(Map<String, dynamic>.from(nested));
    }
    final rawType = (playInfo['type'] ?? merged['type'] ?? entryType)
        ?.toString();
    // play/info 对 TV 条目可能直接解析到默认 Episode，因此目录类型必须优先采用
    // 列表条目的 TV 身份，否则详情页会被降级成“只有当前单集”。
    final type = entryType == 'TV' ? 'TV' : rawType;
    final headers = await imageHeaders(server);
    final enriched = _itemToEntry(server, {
      ...?entry.raw,
      ...merged,
      'guid': guid,
      'type': type ?? 'Video',
    }, headers);
    var seasons = const <SourceEntry>[];
    String? seriesGuid;
    if (type == 'TV') {
      seriesGuid = guid;
      seasons = await _listSeasons(server, guid);
    } else if (type == 'Episode') {
      // 从单集（继续观看/搜索入口）进入详情时，沿 Episode → Season → TV
      // 反查整部剧，确保仍能展示全部季集，而不是只剩当前一集。
      final seasonGuid =
          (playInfo['parent_guid'] ?? merged['parent_guid'])?.toString() ?? '';
      if (seasonGuid.isNotEmpty) {
        try {
          final season = await _authed(server, '/item/$seasonGuid');
          final tvGuid = season is Map
              ? season['parent_guid']?.toString() ?? ''
              : '';
          if (tvGuid.isNotEmpty) {
            seriesGuid = tvGuid;
            seasons = await _listSeasons(server, tvGuid);
          }
        } catch (_) {
          // 反查失败不阻断当前单集详情与播放。
        }
      }
    }
    return FeiniuItemDetail(
      entry: enriched,
      item: merged,
      playInfo: playInfo,
      seasons: seasons,
      seriesGuid: seriesGuid,
    );
  }

  @override
  Future<List<SourceEntry>> search(ServerConfig server, String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];
    final encoded = Uri.encodeQueryComponent(keyword);
    Object? firstError;
    dynamic data;

    // 不同 fnOS 版本对搜索端点实现差异很大：抓包记录显示
    // /item/search 在部分版本返回 501，/search/list 也可能不存在。
    // 先尝试原生接口，但保留真实错误，不能再统一吞成“检查版本”。
    for (final suffix in <String>[
      '/search/list?q=$encoded',
      '/item/search?q=$encoded',
    ]) {
      try {
        data = await _authed(server, suffix);
        break;
      } catch (error) {
        firstError ??= error;
      }
    }

    // 飞牛媒体库的兼容兜底：逐库分页拉取 Movie/TV，再在客户端按标题过滤。
    // 这是当前实测接口最稳定的路径，且不依赖未实现的 search API。
    if (data == null) {
      try {
        data = await _searchFromLibraries(server, keyword);
      } catch (error) {
        throw SourceException(
          '飞牛搜索失败：${error is SourceException ? error.message : firstError ?? error}',
          cause: error,
        );
      }
    }

    final list = data is List
        ? data
        : ((data is Map ? data['list'] : null) as List? ?? const []);
    final headers = await imageHeaders(server);
    return list.whereType<Map>().map((value) {
      final raw = Map<String, dynamic>.from(value);
      raw['poster'] ??= _posterOf(raw);
      return _itemToEntry(server, raw, headers);
    }).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _searchFromLibraries(
      ServerConfig server, String keyword) async {
    final libraries = await _listLibraries(server);
    final lowered = keyword.toLowerCase();
    final results = <Map<String, dynamic>>[];
    for (final library in libraries) {
      final guid = library.id.startsWith('lib:')
          ? library.id.substring(4)
          : library.id;
      for (final type in const ['Movie', 'TV']) {
        var page = 1;
        while (page <= 100) {
          final data = await _authed(server, '/item/list', data: {
            'ancestor_guid': guid,
            'tags': {'type': [type]},
            'exclude_grouped_video': 1,
            'sort_type': 'DESC',
            'sort_column': 'create_time',
            'page': page,
            'page_size': 500,
          });
          final map = data is Map ? data : const <String, dynamic>{};
          final list = map['list'] is List ? map['list'] as List : const [];
          for (final value in list.whereType<Map>()) {
            final item = Map<String, dynamic>.from(value);
            final text = [
              item['title'],
              item['name'],
              item['original_title'],
              item['sort_title'],
            ].where((value) => value != null).join(' ').toLowerCase();
            if (text.contains(lowered)) results.add(item);
          }
          if (list.length < 500) break;
          page++;
        }
      }
    }
    return results;
  }

  Future<FeiniuMediaDetails> mediaDetails(
    ServerConfig server,
    SourceEntry entry,
  ) async {
    final playRaw = await _authed(server, '/play/info', data: {
      'item_guid': entry.id,
    });
    final playInfo = playRaw is Map
        ? Map<String, dynamic>.from(playRaw)
        : <String, dynamic>{};
    final mediaGuid = playInfo['media_guid']?.toString() ?? '';
    if (mediaGuid.isEmpty) {
      return FeiniuMediaDetails(playInfo: playInfo, stream: const {});
    }

    var stream = <String, dynamic>{};
    try {
      final username = server.username ?? 'video';
      final streamRaw = await _authed(server, '/stream', data: {
        'header': {
          'User-Agent': [
            'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 WJPlayer'
          ],
        },
        'level': 1,
        'media_guid': mediaGuid,
        'ip': md5.convert(utf8.encode(username)).toString(),
        'nonce': (100000 + _rand.nextInt(900000)).toString(),
      });
      if (streamRaw is Map) {
        stream = Map<String, dynamic>.from(streamRaw);
      }
    } catch (_) {
      // 部分飞牛版本不支持 /stream，继续用 stream/list 回退轨道数据。
    }

    try {
      final listRaw = await _authed(server, '/stream/list/$mediaGuid');
      if (listRaw is Map) {
        final list = Map<String, dynamic>.from(listRaw);
        for (final key in const [
          'video_stream',
          'audio_streams',
          'subtitle_streams',
          'file_stream',
        ]) {
          final current = stream[key];
          if (current == null || (current is List && current.isEmpty)) {
            stream[key] = list[key];
          }
        }
      }
    } catch (_) {
      // STRM 服务端可能拒绝 stream/list，/stream 已有数据时不受影响。
    }

    return FeiniuMediaDetails(playInfo: playInfo, stream: stream);
  }

  @override
  Future<ResolvedPlay> resolvePlay(
    ServerConfig server,
    SourceEntry entry, {
    String? qualityId,
  }) async {
    final response = await _authed(server, '/play/info', data: {
      'item_guid': entry.id,
    });
    final info = response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
    final mediaGuid = info['media_guid']?.toString() ?? '';
    if (mediaGuid.isEmpty) throw SourceException('未获取到播放媒体');

    final token = _tokenCache[server.id] ?? server.authToken ?? '';
    final base = normalizeBaseUrl(server.activeLineUrl);
    final streamPath = '$_apiPrefix/media/range/$mediaGuid';
    final headers = <String, String>{
      // 与飞牛参考客户端 ApiClient.headers 一致。视频 Range 端点同样需要
      // Content-Type，部分部署会校验此头。
      'Content-Type': 'application/json',
      'Cookie': 'mode=relay',
      if (token.isNotEmpty) 'Authorization': token,
    };

    final resumeSeconds = (info['ts'] as num?)?.toInt() ?? 0;
    return ResolvedPlay(
      url: '$base$streamPath',
      title: entry.name,
      httpHeaders: headers,
      subtitles: await _externalSubs(server, mediaGuid, base, token),
      resumePosition:
          resumeSeconds > 0 ? Duration(seconds: resumeSeconds) : null,
      sourceMetadata: {
        'item_guid': (info['guid'] ?? entry.id).toString(),
        'media_guid': mediaGuid,
        'video_guid': (info['video_guid'] ?? '').toString(),
        'audio_guid': (info['audio_guid'] ?? '').toString(),
        'subtitle_guid': (info['subtitle_guid'] ?? '').toString(),
      },
    );
  }

  Future<void> recordPlayback(
    ServerConfig server, {
    required Map<String, dynamic> playMetadata,
    required Duration position,
    required Duration duration,
  }) async {
    if (duration <= Duration.zero) return;
    final itemGuid = playMetadata['item_guid']?.toString() ?? '';
    final mediaGuid = playMetadata['media_guid']?.toString() ?? '';
    if (itemGuid.isEmpty || mediaGuid.isEmpty) return;
    await _authed(server, '/play/record', data: {
      'item_guid': itemGuid,
      'media_guid': mediaGuid,
      'video_guid': playMetadata['video_guid']?.toString() ?? '',
      'audio_guid': playMetadata['audio_guid']?.toString() ?? '',
      'subtitle_guid': playMetadata['subtitle_guid']?.toString() ?? '',
      'resolution': '原画',
      'bitrate': 0,
      'ts': position.inSeconds.clamp(0, duration.inSeconds),
      'duration': duration.inSeconds,
    });
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
          },
        );
      }).toList();
    } catch (_) {
      return const []; // 字幕拉取失败不影响正片播放。
    }
  }
}
