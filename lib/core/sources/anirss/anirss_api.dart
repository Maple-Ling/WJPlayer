import 'dart:convert';

import 'package:dio/dio.dart';

import '../../providers/server_providers.dart';
import '../source_http.dart';
import 'anirss_token.dart';
import 'models/about.dart';
import 'models/ani.dart';
import 'models/ani_config.dart';
import 'models/bgm_info.dart';
import 'models/bgm_me.dart';
import 'models/discover.dart';
import 'models/log_entry.dart';
import 'models/play_item.dart';
import 'models/tmdb_group.dart';
import 'models/torrent_info.dart';

/// Ani-rss 类型化客户端：浏览/详情/订阅/下载/设置全部端点。
/// 复用 [AniRssAuth] 的 token 生命周期（与播放后端 `AniRssBackend` 共享）。
class AniRssApi {
  final ServerConfig server;
  AniRssApi(this.server);

  AniRssAuth get _auth => AniRssAuth.instance;

  // ---- 浏览 / 详情 ----

  /// 订阅列表 → 展平 weekList[].items 去重。
  Future<List<AniModel>> listAni() async {
    final resp = await _auth.authed(server, '/api/listAni');
    final data = _auth.unwrap(resp);
    final weekList = (data is Map ? data['weekList'] as List? : null) ?? const [];
    final out = <AniModel>[];
    final seen = <String>{};
    for (final w in weekList) {
      final items = (w is Map ? w['items'] as List? : null) ?? const [];
      for (final a in items) {
        final ani = AniModel.fromJson(a);
        final key = ani.id.isNotEmpty ? ani.id : ani.title;
        if (key.isEmpty || !seen.add(key)) continue;
        out.add(ani);
      }
    }
    return out;
  }

  /// 某番剧的剧集文件列表。
  Future<List<PlayItemModel>> playList(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/playList', data: ani.toJson());
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => PlayItemModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// TMDB 剧集组（进阶用）。
  Future<List<TmdbGroupModel>> getThemoviedbGroup(AniModel ani) async {
    final resp =
        await _auth.authed(server, '/api/getThemoviedbGroup', data: ani.toJson());
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => TmdbGroupModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---- 下载进度 ----

  Future<List<TorrentInfoModel>> torrentsInfos() async {
    final resp = await _auth.authed(server, '/api/torrentsInfos');
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => TorrentInfoModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---- 订阅管理 ----

  /// BGM 搜索（添加订阅用）。
  Future<List<BgmInfoModel>> searchBgm(String name) async {
    final resp = await _auth.authed(server, '/api/searchBgm',
        queryParameters: {'name': name});
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => BgmInfoModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 由 BGM 条目 id 生成可添加的订阅 Ani。
  Future<AniModel> getAniBySubjectId(String id) async {
    final resp = await _auth.authed(server, '/api/getAniBySubjectId',
        queryParameters: {'id': id});
    return AniModel.fromJson(_auth.unwrap(resp));
  }

  Future<void> addAni(AniModel ani) =>
      _auth.authed(server, '/api/addAni', data: ani.toJson());

  Future<void> setAni(AniModel ani) =>
      _auth.authed(server, '/api/setAni', data: ani.toJson());

  Future<void> deleteAni(List<String> ids, {bool deleteFiles = false}) =>
      _auth.authed(server, '/api/deleteAni',
          data: ids, queryParameters: {'deleteFiles': deleteFiles});

  Future<void> refreshAni(String id) =>
      _auth.authed(server, '/api/refreshAni', data: {'id': id});

  Future<void> refreshAll() => _auth.authed(server, '/api/refreshAll');

  Future<void> updateTotalEpisodeNumber(List<String> ids,
          {bool force = false}) =>
      _auth.authed(server, '/api/updateTotalEpisodeNumber',
          data: ids, queryParameters: {'force': force});

  Future<void> batchEnable(List<String> ids, bool value) =>
      _auth.authed(server, '/api/batchEnable',
          data: ids, queryParameters: {'value': value});

  // ---- 设置 / 关于 ----

  Future<ConfigModel> config() async {
    final resp = await _auth.authed(server, '/api/config');
    return ConfigModel.fromJson(_auth.unwrap(resp));
  }

  Future<void> setConfig(ConfigModel config) =>
      _auth.authed(server, '/api/setConfig', data: config.toJson());

  Future<AboutModel> about() async {
    final resp = await _auth.authed(server, '/api/about');
    return AboutModel.fromJson(_auth.unwrap(resp));
  }

  // ---- 订阅预览 / 标题解析 / 刮削 / 下载位置 ----

  /// 预览订阅会匹配到的剧集（添加前确认）。返回服务端原始 Map（含 items 等）。
  Future<Map<String, dynamic>> previewAni(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/previewAni', data: ani.toJson());
    final data = _auth.unwrap(resp);
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// 从匹配结果里提取条目列表（previewAni 的 data 可能用不同 key 装 List）。
  static List<Map<String, dynamic>> itemsOf(Map<String, dynamic> preview) {
    for (final v in preview.values) {
      if (v is List && v.isNotEmpty && v.first is Map) {
        return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      }
    }
    return const [];
  }

  /// 获取该订阅的下载落地位置（服务端原始 Map）。
  Future<Map<String, dynamic>> downloadPath(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/downloadPath', data: ani.toJson());
    final data = _auth.unwrap(resp);
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// 解析 BGM 标题（返回标题字符串）。
  Future<String> getBgmTitle(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/getBgmTitle', data: ani.toJson());
    return _auth.unwrap(resp)?.toString() ?? '';
  }

  /// 解析 TMDB 标题（返回回填后的 Ani）。
  Future<AniModel> getThemoviedbName(AniModel ani) async {
    final resp =
        await _auth.authed(server, '/api/getThemoviedbName', data: ani.toJson());
    return AniModel.fromJson(_auth.unwrap(resp));
  }

  /// 刷新封面（返回新封面地址）。
  Future<String> refreshCover(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/refreshCover', data: ani.toJson());
    return _auth.unwrap(resp)?.toString() ?? '';
  }

  /// 刮削单个订阅。
  Future<void> scrape(AniModel ani, {bool force = false}) =>
      _auth.authed(server, '/api/scrape',
          data: ani.toJson(), queryParameters: {'force': force});

  /// 批量刮削。
  Future<void> batchScrape(List<String> ids, {bool force = false}) =>
      _auth.authed(server, '/api/batchScrape',
          data: ids, queryParameters: {'force': force});

  // ---- BGM 评分 / 账号 ----

  /// 读取当前已记录的评分（0=未评）。
  Future<int> rate(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/rate', data: ani.toJson());
    return (_auth.unwrap(resp) as num?)?.toInt() ?? 0;
  }

  /// 提交评分（1~10）。Ani 内带 score/评分字段。
  Future<int> setRate(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/setRate', data: ani.toJson());
    return (_auth.unwrap(resp) as num?)?.toInt() ?? 0;
  }

  /// 当前 BGM 账号信息。
  Future<BgmMeModel> meBgm() async {
    final resp = await _auth.authed(server, '/api/meBgm');
    return BgmMeModel.fromJson(_auth.unwrap(resp));
  }

  // ---- 多搜索源（添加订阅）：Mikan / AniBT / AnimeGarden ----

  /// Mikan 季度番表。[text] 搜索关键词（空取全部），[season] 选定季度（可空取当前）。
  Future<MikanModel> mikan({String text = '', SeasonModel? season}) async {
    final resp = await _auth.authed(server, '/api/mikan',
        data: season?.toJson() ?? <String, dynamic>{},
        queryParameters: {'text': text});
    return MikanModel.fromJson(_auth.unwrap(resp));
  }

  /// 某 Mikan 番剧的字幕组列表（[url] = MikanInfo.url）。
  Future<List<GroupModel>> mikanGroup(String url) =>
      _groupList('/api/mikanGroup', {'url': url});

  /// AniBT 番表。
  Future<AniBTModel> aniBT() async {
    final resp = await _auth.authed(server, '/api/aniBT');
    return AniBTModel.fromJson(_auth.unwrap(resp));
  }

  /// 某 AniBT 番剧的字幕组列表（[bgmId]）。
  Future<List<GroupModel>> aniBTGroup(String bgmId) =>
      _groupList('/api/aniBTGroup', {'bgmId': bgmId});

  /// AnimeGarden 番表（按星期分组）。
  Future<List<WeekModel>> animeGardenList() async {
    final resp = await _auth.authed(server, '/api/animeGardenList');
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => WeekModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 某 AnimeGarden 番剧的字幕组列表（[bgmId]）。
  Future<List<GroupModel>> animeGardenGroup(String bgmId) =>
      _groupList('/api/animeGardenGroup', {'bgmId': bgmId});

  Future<List<GroupModel>> _groupList(
      String path, Map<String, dynamic> query) async {
    final resp = await _auth.authed(server, path, queryParameters: query);
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => GroupModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 由 RSS 生成订阅 Ani（之后 addAni 添加）。[type] = mikan/ani-bt/anime-garden/other。
  Future<AniModel> rssToAni({
    required String url,
    String type = 'mikan',
    String? bgmUrl,
    String subgroup = '未知字幕组',
    bool enable = true,
  }) async {
    final resp = await _auth.authed(server, '/api/rssToAni', data: {
      'url': url,
      'type': type,
      if (bgmUrl != null) 'bgmUrl': bgmUrl,
      'subgroup': subgroup,
      'enable': enable,
    });
    return AniModel.fromJson(_auth.unwrap(resp));
  }

  // ---- 播放：内封/外挂字幕 ----

  /// 获取某文件的字幕（[filename] = PlayItem.filename 的 base64，勿再编码）。
  /// 返回内封被提取/外挂可下载的字幕（含 url 或 content）。
  Future<List<SubtitleModel>> getSubtitles(String filename) async {
    final resp = await _auth.authed(server, '/api/getSubtitles',
        queryParameters: {'filename': filename});
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => SubtitleModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---- 诊断 / 日志 / 维护 ----

  /// 运行日志（最近若干条）。
  Future<List<LogEntryModel>> logs() async {
    final resp = await _auth.authed(server, '/api/logs');
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => LogEntryModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 下载日志（纯文本）。
  Future<String> downloadLogs() async {
    final resp = await _auth.authed(server, '/api/downloadLogs', method: 'GET');
    final body = resp.data;
    if (body is String) return body;
    if (body is Map && body['data'] != null) return body['data'].toString();
    return body?.toString() ?? '';
  }

  Future<void> clearLogs() => _auth.authed(server, '/api/clearLogs');

  Future<void> clearCache() => _auth.authed(server, '/api/clearCache');

  /// 存活测试（GET /api/ping）。失败抛异常。
  Future<void> ping() => _auth.authed(server, '/api/ping', method: 'GET');

  /// 下载器登录测试（用当前服务端配置）。
  Future<void> downloadLoginTest(ConfigModel config) =>
      _auth.authed(server, '/api/downloadLoginTest', data: config.toJson());

  /// 代理测试，返回 {status, time(ms)}。
  Future<Map<String, dynamic>> testProxy(String url, ConfigModel config) async {
    final resp = await _auth.authed(server, '/api/testProxy',
        data: config.toJson(), queryParameters: {'url': url});
    final data = _auth.unwrap(resp);
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// IP 白名单测试。
  Future<void> testIpWhitelist() =>
      _auth.authed(server, '/api/testIpWhitelist');

  /// 触发服务端自更新（升级 ani-rss 本体）。
  Future<void> update() => _auth.authed(server, '/api/update');

  /// 停止/重启服务（[status] 由服务端定义，0 通常为停止）。
  Future<void> stop({int status = 0}) =>
      _auth.authed(server, '/api/stop', queryParameters: {'status': status});

  /// 最新一条通知配置（用于「测试通知」预填等）。返回原始 Map。
  Future<Map<String, dynamic>> newNotification() async {
    final resp = await _auth.authed(server, '/api/newNotification');
    final data = _auth.unwrap(resp);
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// Emby 媒体库列表（配置 Emby 通知时挑库用）。body 为通知配置 Map。
  Future<List<Map<String, String>>> getEmbyViews(
      Map<String, dynamic> notificationConfig) async {
    final resp = await _auth.authed(server, '/api/getEmbyViews',
        data: notificationConfig);
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => {
              'id': e['id']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            })
        .toList();
  }

  /// 导出设置的可下载 URL（带登录令牌查询参数；交给浏览器/系统打开）。
  Future<String> exportConfigUrl() async {
    final token = await _auth.ensureToken(server);
    final base = normalizeBaseUrl(server.activeLineUrl);
    return '$base/api/exportConfig'
        '?${AniRssAuth.queryAuthKey}=${Uri.encodeQueryComponent(token)}';
  }

  /// 导入设置（上传配置文件字节）。
  Future<void> importConfig(List<int> bytes, String filename) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    await _auth.authed(server, '/api/importConfig', data: form);
  }

  // ---- 图片代理 ----

  /// 经 ani-rss 服务端代理/缓存取图（TMDB 相对路径等）。需 token → async。
  Future<String> proxyImageUrl(String imgUrl) async {
    final token = await _auth.ensureToken(server);
    return buildProxyImageUrl(server, imgUrl, token);
  }

  /// 同步构造 proxyImage URL（已有 token 时用，如详情 provider 预解析后）。
  ///
  /// 服务端 `ProxyImageController` 对 `imgUrl` 做 **Base64 解码**，故须先 base64 编码原始
  /// 图片地址；鉴权用 `s=<登录令牌>` 走 Form 鉴权（URL 无法带 Authorization 头）。
  static String buildProxyImageUrl(
      ServerConfig server, String imgUrl, String token) {
    final base = normalizeBaseUrl(server.activeLineUrl);
    final encoded = base64.encode(utf8.encode(imgUrl));
    return '$base/api/proxyImage'
        '?imgUrl=${Uri.encodeQueryComponent(encoded)}'
        '&${AniRssAuth.queryAuthKey}=${Uri.encodeQueryComponent(token)}';
  }
}
