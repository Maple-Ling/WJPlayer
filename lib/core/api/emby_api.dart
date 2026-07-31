import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../app_identity.dart';
import '../network/proxy_http_client.dart';
import '../network/proxy_settings.dart';
import 'api_interfaces.dart';

class EmbyApiClient implements ApiClientFactory {
  late Dio _dio;
  String _currentLine;
  String? _authToken;
  String? _userId;
  void Function()? _proxyListenerCancel;

  EmbyApiClient({required String baseUrl, String? authToken, String? userId})
      : _currentLine = baseUrl,
        _authToken = authToken,
        _userId = userId {
    _dio = _createDio(baseUrl, authToken);
    _registerProxyListener();
  }

  static Dio _createDio(String baseUrl, String? authToken) {
    // 确保 baseUrl 以 / 结尾，避免 Dio 拼接路径时丢失子路径
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
        'X-Emby-Authorization':
            'MediaBrowser Client="WJPlayer", Device="Mobile", DeviceId="wjplayer-mobile", Version="$kAppVersion"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'wjplayer-mobile',
        'X-Emby-Client': 'WJPlayer',
        'X-Emby-Client-Version': kAppVersion,
        if (authToken != null) 'X-Emby-Token': authToken,
      },
    ));

    // 自签名证书放行 + 用户自定义代理（HTTP/SOCKS）统一接入。
    applyProxyToDio(dio);

    // 兼容性拦截器：把鉴权 token 以 api_key 查询参数附加到所有请求，
    // 同时保留 header 鉴权（X-Emby-Token）。部分服务端依赖查询参数授权，
    // 而把冗长的 X-Emby-Authorization 串塞进 query 会触发 Cloudflare WAF，
    // 因此这里只补 api_key，并主动剔除 query 中的 X-Emby-Authorization。
    dio.interceptors.add(_EmbyAuthQueryCompatInterceptor());

    // 仅 debug 构建记录请求行，且**不**打印请求体/请求头/响应体，避免登录
    // 密码（Pw）与 X-Emby-Token / api_key 落入日志。release 完全不挂日志拦截器。
    if (kDebugMode) {
      dio.interceptors.add(LogInterceptor(
        request: true,
        requestBody: false,
        requestHeader: false,
        responseBody: false,
      ));
    }
    return dio;
  }

  void _rebuildDio() {
    _dio = _createDio(_currentLine, _authToken);
    _registerProxyListener();
  }

  /// 监听全局代理变更，实时让当前 Dio 重建底层连接。
  void _registerProxyListener() {
    _proxyListenerCancel?.call();
    final dio = _dio;
    _proxyListenerCancel =
        ProxyRuntime.instance.addListener(() => refreshDioProxy(dio));
  }

  String? get userId => _userId;

  @override
  AuthApi get auth => EmbyAuthApi(this);

  @override
  UserApi get user => EmbyUserApi(this);

  @override
  ServerApi get server => EmbyServerApi(this);

  @override
  HomeApi get home => EmbyHomeApi(this);

  @override
  LibraryApi get library => EmbyLibraryApi(this);

  @override
  MediaApi get media => EmbyMediaApi(this);

  @override
  SearchApi get search => EmbySearchApi(this);

  @override
  PlaybackApi get playback => EmbyPlaybackApi(this);

  @override
  FavoriteApi get favorite => EmbyFavoriteApi(this);

  @override
  ImageApi get image => EmbyImageApi(this);

  @override
  void switchLine(String lineUrl) {
    _currentLine = lineUrl;
    _rebuildDio();
  }

  @override
  String get currentLine => _currentLine;

  @override
  void setAuthToken(String token) {
    _authToken = token;
    _dio.options.headers['X-Emby-Token'] = token;
  }

  @override
  void clearAuth() {
    _authToken = null;
    _userId = null;
    _dio.options.headers.remove('X-Emby-Token');
  }

  /// 释放底层 Dio 连接并注销代理监听。
  ///
  /// 构造函数会向 [ProxyRuntime] 注册一个监听器；临时创建的 client（如聚合搜索
  /// 为其它服务器建的只读 client）若不释放，会持续泄漏监听器。长生命周期的主
  /// client 不必调用。
  void dispose() {
    _proxyListenerCancel?.call();
    _proxyListenerCancel = null;
    _dio.close(force: true);
  }

  /// 仅在「请求尚未抵达服务器」的瞬时连接错误上重试：TLS 握手被中断
  /// （HandshakeException: Connection terminated during handshake）、连接
  /// 超时、Socket 中断等。此类失败发生在收到任何 HTTP 响应**之前**，服务端
  /// 未收到请求，因此即便是 POST 重试也不会产生重复副作用。
  ///
  /// 反例：一旦收到任意 HTTP 响应（含 4xx/5xx）或进入 receive/send 超时
  /// （请求可能已抵达服务端），一律不重试，避免重复提交。
  static const int _kTransientMaxAttempts = 3;

  static bool _isTransientConnError(Object e) {
    if (e is! DioException) return false;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return true;
    }
    // 部分平台握手中断会被 Dio 归类为 unknown，回退到底层异常类型判断。
    final inner = e.error;
    return inner is HandshakeException || inner is SocketException;
  }

  /// 幂等请求（GET/DELETE）可安全重试的网关瞬时错误：
  /// - 502/503/504：网关收到请求但上游（Emby/反代）临时不可用或超时，
  ///   上游多半未真正处理业务，重试常在 1~2 次内恢复。这正是「前端连不上
  ///   服务器」的高发原因——一次 504 就判定失联太脆弱。
  /// - receiveTimeout：请求已发出但响应迟迟不回，对幂等读取重试无副作用。
  ///
  /// **只对幂等方法启用**：POST（播放上报/标记已看等）在 504 时无法确定
  /// 上游是否已处理，重试可能重复副作用，故 POST 只走 [_isTransientConnError]。
  static bool _isRetryableGatewayError(Object e) {
    if (e is! DioException) return false;
    final code = e.response?.statusCode;
    if (code == 502 || code == 503 || code == 504) return true;
    return e.type == DioExceptionType.receiveTimeout;
  }

  /// 瞬时错误自动重试。[retryGateway] 为 true 时（仅幂等 GET/DELETE）
  /// 额外重试 502/503/504/receiveTimeout。供实例请求与服务器探测复用。
  static Future<Response<T>> _withRetry<T>(
      Future<Response<T>> Function() send,
      {bool retryGateway = false}) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await send();
      } catch (e) {
        final retryable = _isTransientConnError(e) ||
            (retryGateway && _isRetryableGatewayError(e));
        if (attempt >= _kTransientMaxAttempts || !retryable) {
          rethrow;
        }
        // 线性退避：300ms / 600ms，避开瞬时网络抖动与网关瞬时抽风。
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  /// 包装 Dio.get，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃。
  /// [cancelToken] 透传给 Dio：调用方（如聚合/搜索 provider）离开页面时可直接杀请求。
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    return _withRetry(
        () => _dio.get<T>(
              path.startsWith('/') ? path.substring(1) : path,
              queryParameters: queryParameters,
              options: options,
              cancelToken: cancelToken,
            ),
        retryGateway: true);
  }

  /// 包装 Dio.post，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> post<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    return _withRetry(() => _dio.post<T>(
          path.startsWith('/') ? path.substring(1) : path,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken,
        ));
  }

  /// 包装 Dio.delete，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> delete<T>(String path,
      {dynamic data, Map<String, dynamic>? queryParameters, Options? options}) {
    return _withRetry(
        () => _dio.delete<T>(
              path.startsWith('/') ? path.substring(1) : path,
              data: data,
              queryParameters: queryParameters,
              options: options,
            ),
        retryGateway: true);
  }
}

/// 兼容性拦截器：所有 Dio 请求附加 `api_key` 查询参数（同时保留 header 鉴权），
/// 并剔除 query 中的 `X-Emby-Authorization`（其冗长字符串会触发 Cloudflare 等 CDN
/// 的安全策略）。这样既兼容「依赖查询参数授权」的服务端，又不破坏走 CDN 的服务端。
class _EmbyAuthQueryCompatInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) {
    final token = options.headers['X-Emby-Token'];
    if (token is String &&
        token.isNotEmpty &&
        !options.queryParameters.containsKey('api_key')) {
      options.queryParameters['api_key'] = token;
    }
    options.queryParameters.remove('X-Emby-Authorization');
    handler.next(options);
  }
}

// ==================== Auth ====================

class EmbyAuthApi implements AuthApi {
  final EmbyApiClient _client;
  EmbyAuthApi(this._client);

  @override
  Future<AuthResult> login(
      {required String username, required String password}) async {
    if (kDebugMode) {
      debugPrint('[EmbyAPI] login: baseUrl=${_client.currentLine}');
    }

    try {
      final resp = await _client.post('/Users/AuthenticateByName', data: {
        'Username': username,
        'Pw': password,
      });
      if (kDebugMode) debugPrint('[EmbyAPI] login success: ${resp.statusCode}');
      final d = resp.data as Map<String, dynamic>;
      final userData = d['User'] as Map<String, dynamic>?;
      if (userData == null) {
        throw Exception('Invalid response: User data missing');
      }
      final user = _parseUser(userData);
      if (user.id.isEmpty) {
        throw Exception('Invalid response: User ID missing');
      }
      _client._userId = user.id;
      final token = d['AccessToken'] as String?;
      if (token == null || token.isEmpty) {
        throw Exception('Invalid response: AccessToken missing');
      }
      _client.setAuthToken(token);
      return AuthResult(
        accessToken: token,
        userId: user.id,
        serverId: d['ServerId'] as String? ?? '',
        user: user,
      );
    } on DioException catch (e) {
      // 仅打印类型/状态码：绝不记录 request headers（含 X-Emby-Token）与
      // request data（含明文密码 Pw），即便在 debug 也不打。
      if (kDebugMode) {
        debugPrint('[EmbyAPI] login failed: ${e.type} | ${e.message} | '
            'status=${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _client.post('/Sessions/Logout');
    } finally {
      _client.clearAuth();
    }
  }

  @override
  Future<User> getCurrentUser() async {
    final uid = _currentUserAliasForScopedRequest(_client);
    final resp = await _client.get('/Users/$uid');
    return _parseUser(resp.data as Map<String, dynamic>);
  }

  @override
  Future<AuthResult> refreshToken() async {
    return await login(
      username: _client._userId ?? '',
      password: '',
    );
  }
}

// ==================== User ====================

class EmbyUserApi implements UserApi {
  final EmbyApiClient _client;
  EmbyUserApi(this._client);

  @override
  Future<User> getUser(String userId) async {
    final resp = await _client.get('/Users/$userId');
    return _parseUser(resp.data as Map<String, dynamic>);
  }

  @override
  Future<void> markAsPlayed(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.post('/Users/$uid/PlayedItems/$itemId');
  }

  @override
  Future<void> markAsUnplayed(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.delete('/Users/$uid/PlayedItems/$itemId');
  }
}

// ==================== Server ====================

class EmbyServerApi implements ServerApi {
  final EmbyApiClient _client;
  EmbyServerApi(this._client);

  @override
  Future<ServerInfo> getPublicInfo(String baseUrl) async {
    // 确保 baseUrl 以 / 结尾
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      // 探测服务器也要有超时上限，否则死服务器/网关会把「连接中」挂到 OS 超时。
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
        'X-Emby-Authorization':
            'MediaBrowser Client="WJPlayer", Device="Mobile", DeviceId="wjplayer-mobile", Version="$kAppVersion"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'wjplayer-mobile',
        'X-Emby-Client': 'WJPlayer',
        'X-Emby-Client-Version': kAppVersion,
      },
    ));

    applyProxyToDio(dio);

    debugPrint('[EmbyAPI] getPublicInfo: baseUrl=$normalizedBaseUrl');

    try {
      // 幂等探测：网关瞬时 502/503/504 自动重试，避免一次抽风就判定「连不上」。
      final resp = await EmbyApiClient._withRetry(
          () => dio.get('System/Info/Public'),
          retryGateway: true);
      debugPrint('[EmbyAPI] getPublicInfo success: ${resp.statusCode}');
      return _parseServerInfo(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] getPublicInfo failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint(
          '[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<ServerInfo> getSystemInfo() async {
    final resp = await _client.get('/System/Info');
    return _parseServerInfo(resp.data as Map<String, dynamic>);
  }

  @override
  Future<bool> testConnection(String baseUrl) async {
    try {
      // 确保 baseUrl 以 / 结尾
      final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final dio = Dio(BaseOptions(
        baseUrl: normalizedBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': kAppUserAgent,
          'X-Emby-Authorization':
              'MediaBrowser Client="WJPlayer", Device="Mobile", DeviceId="wjplayer-mobile", Version="$kAppVersion"',
          'X-Emby-Device-Name': 'Mobile',
          'X-Emby-Device-Id': 'wjplayer-mobile',
          'X-Emby-Client': 'WJPlayer',
          'X-Emby-Client-Version': kAppVersion,
        },
      ));
      applyProxyToDio(dio);
      await EmbyApiClient._withRetry(() => dio.get('System/Info/Public'),
          retryGateway: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ==================== Home ====================

class EmbyHomeApi implements HomeApi {
  final EmbyApiClient _client;
  EmbyHomeApi(this._client);

  static const String _mediaFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,BackdropImageTags,ChildCount,RecursiveItemCount,'
      'CanDownload,SupportsSync,ProviderIds,PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<List<MediaItem>> getResumeItems() async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Users/$uid/Items/Resume', queryParameters: {
      'Limit': 12,
      'MediaTypes': 'Video',
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<MediaItem>> getNextUp() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Shows/NextUp', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<Library>> getLibraries() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Views');
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseLibrary(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<MediaCounts> getMediaCounts() async {
    final uid = _requireUserId(_client);
    debugPrint(
        '[EmbyAPI] getMediaCounts: baseUrl=${_client.currentLine}, userId=$uid');

    try {
      final resp = await _client.get('/Items/Counts', queryParameters: {
        'UserId': uid,
      });
      final data = resp.data as Map<String, dynamic>;
      debugPrint('[EmbyAPI] getMediaCounts success: $data');
      return MediaCounts(
        movieCount: (data['MovieCount'] as num?)?.toInt() ?? 0,
        episodeCount: (data['EpisodeCount'] as num?)?.toInt() ?? 0,
        itemCount: (data['ItemCount'] as num?)?.toInt(),
      );
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] getMediaCounts failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint(
          '[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> getLatestItems(String libraryId,
      {int limit = 20}) async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Users/$uid/Items/Latest', queryParameters: {
      'ParentId': libraryId,
      'Limit': limit,
      'Fields': _mediaFields,
    });
    final items = resp.data as List<dynamic>;
    return items
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaItem>> getRandomRecommendations({int limit = 8}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'Limit': limit,
      'SortBy': 'Random',
      'IncludeItemTypes': 'Movie,Series',
      'Recursive': true,
      'Fields': _mediaFields,
    });
    return _parseItemList(resp.data);
  }
}

// ==================== Library ====================

class EmbyLibraryApi implements LibraryApi {
  final EmbyApiClient _client;
  EmbyLibraryApi(this._client);

  static const String _libraryItemFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,ChildCount,RecursiveItemCount,CanDownload,SupportsSync,'
      'ProviderIds,PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<List<MediaItem>> getLibraryItems({
    required String libraryId,
    String? sortBy,
    String? sortOrder,
    int startIndex = 0,
    int limit = 50,
    String? genres,
    String? tags,
    String? studioIds,
    String? studios,
    String? years,
    double? ratingMin,
    double? ratingMax,
  }) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'ParentId': libraryId,
      'UserId': uid,
      'StartIndex': startIndex,
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series',
      'Fields': _libraryItemFields,
    };
    // limit<=0 表示不设上限（Emby 省略 Limit 即返回全部），避免媒体库详情
    // 被截成 50 条不能继续浏览。ponytail: 一次拉全量，若超大库(上万条)出现卡顿
    // 再换游标分页(StartIndex 增量 + 触底加载)。
    if (limit > 0) params['Limit'] = limit;
    if (sortBy != null) {
      params['SortBy'] = sortBy;
      params['SortOrder'] = sortOrder ?? 'Ascending';
    }
    // 服务端过滤：Genres/Tags 用竖线分隔按名、Years 逗号分隔。评分下界走 MinCommunityRating。
    if (genres != null && genres.isNotEmpty) params['Genres'] = genres;
    if (tags != null && tags.isNotEmpty) params['Tags'] = tags;
    if (years != null && years.isNotEmpty) params['Years'] = years;
    if (ratingMin != null) params['MinCommunityRating'] = ratingMin;
    // 工作室优先按 Id（StudioIds）过滤；部分 Emby 对 GUID 严格、格式不符直接 500
    // （同 Filters2 的 "Unrecognized Guid format"），故捕获后退回按名（Studios）重试，
    // 两者标准 Emby/Jellyfin 都支持，确保至少能过滤、不再整页报错。
    final hasStudioId = studioIds != null && studioIds.isNotEmpty;
    final hasStudioName = studios != null && studios.isNotEmpty;
    if (hasStudioId) params['StudioIds'] = studioIds;
    Response resp;
    try {
      resp = await _client.get('/Users/$uid/Items', queryParameters: params);
    } on DioException {
      if (!hasStudioId || !hasStudioName) rethrow;
      params.remove('StudioIds');
      params['Studios'] = studios;
      resp = await _client.get('/Users/$uid/Items', queryParameters: params);
    }
    var list = _parseItemList(resp.data);
    // Emby 无 MaxCommunityRating；评分区间在本页客户端兜底（无评分项视为不在区间）。
    // ponytail: 分页下夹逼后可能不足一页，个人库通常不大，先够用；要严谨需服务端支持上界。
    if (ratingMin != null || ratingMax != null) {
      list = list.where((it) {
        final r = it.communityRating;
        if (r == null) return false;
        if (ratingMin != null && r < ratingMin) return false;
        if (ratingMax != null && r > ratingMax) return false;
        return true;
      }).toList();
    }
    return list;
  }

  @override
  Future<Filters> getFilters(String libraryId) async {
    final uid = _requireUserId(_client);
    // 不走 /Items/Filters：部分 Emby（实测 4.9.5）该端点 404，/Users/{uid}/Items/Filters2
    // 又 500（Unrecognized Guid format）。改用各分面专用端点并行取，
    // 这些端点在标准 Emby 上也都在，兼容性更好；各自吞错互不拖垮。
    final results = await Future.wait<Object>([
      _fetchFacetNames('/Genres', libraryId, uid),
      _fetchFacetNames('/Years', libraryId, uid),
      _fetchFacetNames('/Tags', libraryId, uid),
      _fetchFacetEntries('/Studios', libraryId, uid), // 工作室要 Id 才能过滤
      _fetchFacetNames('/OfficialRatings', libraryId, uid),
    ]);
    final studioMap = results[3] as Map<String, String>;
    return Filters(
      genres: results[0] as List<String>,
      years: results[1] as List<String>,
      tags: results[2] as List<String>,
      studios: studioMap.keys.toList(),
      officialRatings: results[4] as List<String>,
      studioIds: studioMap,
    );
  }

  @override
  Future<List<MediaItem>> getCollections() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'UserId': uid,
      'IncludeItemTypes': 'BoxSet',
      'Recursive': true,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Fields': _libraryItemFields,
    });
    return _parseItemList(resp.data);
  }

  /// 某分面端点（/Genres、/Years、/Tags、/Studios、/OfficialRatings）的库内取值，
  /// 返回 Items[].Name 列表。失败不应拖垮整个面板，故吞错返回空。
  Future<List<String>> _fetchFacetNames(
      String endpoint, String libraryId, String uid) async {
    try {
      final resp = await _client.get(endpoint, queryParameters: {
        'UserId': uid,
        'ParentId': libraryId,
        'Recursive': true,
      });
      final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>?;
      return items
              ?.map((e) => (e as Map<String, dynamic>)['Name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          [];
    } catch (_) {
      return [];
    }
  }

  /// 同 [_fetchFacetNames]，但返回 名→Id 映射（工作室过滤需 StudioIds）。保持服务端
  /// 返回顺序，吞错返回空 map。
  Future<Map<String, String>> _fetchFacetEntries(
      String endpoint, String libraryId, String uid) async {
    try {
      final resp = await _client.get(endpoint, queryParameters: {
        'UserId': uid,
        'ParentId': libraryId,
        'Recursive': true,
      });
      final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>?;
      final map = <String, String>{};
      for (final e in items ?? const []) {
        final m = e as Map<String, dynamic>;
        final name = m['Name']?.toString() ?? '';
        final id = m['Id']?.toString() ?? '';
        if (name.isNotEmpty && id.isNotEmpty) map[name] = id;
      }
      return map;
    } catch (_) {
      return {};
    }
  }
}

// ==================== Media ====================

class EmbyMediaApi implements MediaApi {
  final EmbyApiClient _client;
  EmbyMediaApi(this._client);

  static const String _detailFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,People,Studios,ImageTags,ParentThumbItemId,'
      'ParentThumbImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,'
      'SeriesThumbImageTag,SeriesPrimaryImageTag,BackdropImageTags,'
      'ChildCount,RecursiveItemCount,CanDownload,SupportsSync,ProviderIds,'
      'PresentationUniqueKey,Path,'
      'ParentLogoItemId,ParentLogoImageTag,'
      'BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags';

  @override
  Future<MediaItem> getItemDetails(String itemId,
      {CancelToken? cancelToken}) async {
    if (itemId.isEmpty) {
      throw Exception('无效的媒体ID');
    }
    final uid = _client._userId;
    final params = <String, dynamic>{
      'Fields': _detailFields,
    };
    if (uid != null) params['UserId'] = uid;
    try {
      final resp = await _client.get('/Items/$itemId',
          queryParameters: params, cancelToken: cancelToken);
      return _parseMediaItem(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 && uid != null) {
        try {
          final resp = await _client.get('/Users/$uid/Items/$itemId',
              queryParameters: params, cancelToken: cancelToken);
          return _parseMediaItem(resp.data as Map<String, dynamic>);
        } catch (_) {
          // fallback 失败，继续抛出原始错误
        }
      }
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> getSimilarItems(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Items/$itemId/Similar', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': _detailFields,
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<Season>> getSeasons(String seriesId,
      {CancelToken? cancelToken}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Shows/$seriesId/Seasons',
        cancelToken: cancelToken,
        queryParameters: {
          'UserId': uid,
          'Fields':
              'Overview,ImageTags,SeriesPrimaryImageTag,SeriesThumbImageTag',
        });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parseSeason(e as Map<String, dynamic>, seriesId))
        .toList();
  }

  @override
  Future<List<Episode>> getEpisodes(String seriesId,
      {String? seasonId, CancelToken? cancelToken}) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'UserId': uid,
      'Fields':
          'Overview,RunTimeTicks,ImageTags,ParentThumbItemId,ParentThumbImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,SeriesPrimaryImageTag,CanDownload,SupportsSync,MediaSources',
    };
    if (seasonId != null) params['SeasonId'] = seasonId;
    final resp = await _client.get('/Shows/$seriesId/Episodes',
        queryParameters: params, cancelToken: cancelToken);
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseEpisode(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Person>> getPersonItems(String personName) async {
    final uid = _requireUserId(_client);
    final resp =
        await _client.get('/Persons/$personName/Items', queryParameters: {
      'UserId': uid,
      'Limit': 20,
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items
        .map((e) => _parsePersonFromItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaItem>> findItemsByProviderIds(
    Map<String, String> providerIds, {
    String? includeItemTypes,
    int limit = 10,
    CancelToken? cancelToken,
  }) async {
    final anyEquals = providerIds.entries
        .where((e) => e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
        .map((e) => '${e.key.trim().toLowerCase()}.${e.value.trim()}')
        .join(',');
    if (anyEquals.isEmpty) return const <MediaItem>[];
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'UserId': uid,
      'Recursive': true,
      'AnyProviderIdEquals': anyEquals,
      'Limit': limit,
      'Fields': _detailFields,
    };
    if (includeItemTypes != null && includeItemTypes.isNotEmpty) {
      params['IncludeItemTypes'] = includeItemTypes;
    }
    final resp = await _client.get('/Users/$uid/Items',
        queryParameters: params, cancelToken: cancelToken);
    final items =
        (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>? ??
            const <dynamic>[];
    return items
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaSource>> getItemMediaSources(String itemId,
      {CancelToken? cancelToken}) async {
    if (itemId.isEmpty) return const <MediaSource>[];
    final uid = _client._userId;
    final params = <String, dynamic>{'Fields': 'MediaSources,MediaStreams'};
    if (uid != null) params['UserId'] = uid;
    Map<String, dynamic> data;
    try {
      final resp = await _client.get('/Items/$itemId',
          queryParameters: params, cancelToken: cancelToken);
      data = resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 && uid != null) {
        final resp = await _client.get('/Users/$uid/Items/$itemId',
            queryParameters: params, cancelToken: cancelToken);
        data = resp.data as Map<String, dynamic>;
      } else {
        rethrow;
      }
    }
    final sources = (data['MediaSources'] as List<dynamic>?) ?? const [];
    return sources
        .map((e) => _parseMediaSource(e as Map<String, dynamic>))
        .toList();
  }
}

// ==================== Search ====================

class EmbySearchApi implements SearchApi {
  final EmbyApiClient _client;
  EmbySearchApi(this._client);

  @override
  Future<List<MediaItem>> getSearchHints(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Search/Hints', queryParameters: {
      'UserId': uid,
      'SearchTerm': query,
      'Limit': 20,
    });
    final hints =
        (resp.data as Map<String, dynamic>)['SearchHints'] as List<dynamic>;
    return hints
        .map((e) => _parseMediaItem(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MediaItem>> search(String query,
      {bool recursive = true, CancelToken? cancelToken}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items',
        cancelToken: cancelToken,
        queryParameters: {
          'SearchTerm': query,
          'Recursive': recursive,
          'Limit': 50,
          'Fields':
              'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber,ProviderIds,PresentationUniqueKey,Path,ChildCount,RecursiveItemCount',
        });
    return _parseItemList(resp.data);
  }

  @override
  Future<Map<String, List<MediaItem>>> searchAggregate(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'SearchTerm': query,
      'Recursive': true,
      'Limit': 50,
      'Fields':
          'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber,ProviderIds,PresentationUniqueKey,Path',
    });
    final items = _parseItemList(resp.data);
    final serverName = _client._dio.options.baseUrl;
    return {serverName: items};
  }
}

// ==================== Playback ====================

class EmbyPlaybackApi implements PlaybackApi {
  final EmbyApiClient _client;
  EmbyPlaybackApi(this._client);

  @override
  Future<PlaybackInfo> getPlaybackInfo(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.post('/Items/$itemId/PlaybackInfo', data: {
      'UserId': uid,
      'StartTimeTicks': 0,
      'IsPlayback': true,
      'AutoOpenLiveStream': true,
    });
    return _parsePlaybackInfo(resp.data as Map<String, dynamic>, itemId);
  }

  @override
  String getVideoStreamUrl(
    String itemId, {
    String? mediaSourceId,
    String? container,
    String? playSessionId,
    bool staticStream = true,
    bool allowDirectPlay = true,
    bool allowDirectStream = true,
    bool allowTranscoding = false,
    bool enableAutoStreamCopy = true,
    bool enableAutoStreamCopyAudio = true,
    bool enableAutoStreamCopyVideo = true,
  }) {
    final base = _client._currentLine.endsWith('/')
        ? _client._currentLine.substring(0, _client._currentLine.length - 1)
        : _client._currentLine;
    final token = _client._authToken;
    final normalizedContainer = (container ?? 'mkv').trim().toLowerCase();
    final safeContainer =
        normalizedContainer.isEmpty ? 'mkv' : normalizedContainer;
    final params = <String>[
      'static=$staticStream',
      'download=false',
      'EnableAutoStreamCopy=$enableAutoStreamCopy',
      'EnableAutoStreamCopyAudio=$enableAutoStreamCopyAudio',
      'EnableAutoStreamCopyVideo=$enableAutoStreamCopyVideo',
      'EnableDirectPlay=$allowDirectPlay',
      'EnableDirectStream=$allowDirectStream',
      'EnableTranscoding=$allowTranscoding',
      if (mediaSourceId != null && mediaSourceId.isNotEmpty)
        'MediaSourceId=${Uri.encodeQueryComponent(mediaSourceId)}',
      if (playSessionId != null && playSessionId.isNotEmpty)
        'PlaySessionId=${Uri.encodeQueryComponent(playSessionId)}',
      if (token != null) 'api_key=${Uri.encodeQueryComponent(token)}',
    ];
    return '$base/Videos/$itemId/stream.$safeContainer?${params.join('&')}';
  }

  @override
  String getSubtitleStreamUrl(
      String itemId, String mediaSourceId, int index, String codec) {
    final base = _client._currentLine;
    final token = _client._authToken;
    return '$base/Videos/$itemId/$mediaSourceId/Subtitles/$index/Stream.$codec${token != null ? '?api_key=$token' : ''}';
  }

  @override
  String getDownloadUrl(String itemId, {String? mediaSourceId}) {
    final base = _client._currentLine.endsWith('/')
        ? _client._currentLine.substring(0, _client._currentLine.length - 1)
        : _client._currentLine;
    final token = _client._authToken;
    final params = <String>[
      if (mediaSourceId != null && mediaSourceId.isNotEmpty)
        'MediaSourceId=${Uri.encodeQueryComponent(mediaSourceId)}',
      if (token != null) 'api_key=${Uri.encodeQueryComponent(token)}',
    ];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '$base/Items/$itemId/Download$query';
  }

  @override
  Future<void> reportPlaybackStart(PlaybackStartInfo info) async {
    await _client.post('/Sessions/Playing', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'AudioStreamIndex': info.audioStreamIndex,
      'SubtitleStreamIndex': info.subtitleStreamIndex,
      'PlayMethod': info.playMethod ?? 'DirectStream',
      if (info.playSessionId != null) 'PlaySessionId': info.playSessionId,
    });
  }

  @override
  Future<void> reportPlaybackProgress(PlaybackProgressInfo info) async {
    await _client.post('/Sessions/Playing/Progress', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
      'IsPaused': info.isPaused,
      'IsMuted': info.isMuted,
      'VolumeLevel': (info.volumeLevel * 100).round(),
      if (info.playSessionId != null) 'PlaySessionId': info.playSessionId,
    });
  }

  @override
  Future<void> reportPlaybackStopped(PlaybackStopInfo info) async {
    await _client.post('/Sessions/Playing/Stopped', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
      if (info.playSessionId != null) 'PlaySessionId': info.playSessionId,
    });
  }
}

// ==================== Favorite ====================

class EmbyFavoriteApi implements FavoriteApi {
  final EmbyApiClient _client;
  EmbyFavoriteApi(this._client);

  static const String _favoriteFields =
      'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,'
      'RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,'
      'ParentIndexNumber,ImageTags,ParentThumbItemId,ParentThumbImageTag,'
      'ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesThumbImageTag,'
      'SeriesPrimaryImageTag,BackdropImageTags,ChildCount,RecursiveItemCount,'
      'CanDownload,SupportsSync,ParentLogoItemId,ParentLogoImageTag';

  @override
  Future<List<MediaItem>> getFavorites() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'Filters': 'IsFavorite',
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series,Season,Episode',
      'SortBy': 'DateCreated,SortName',
      'SortOrder': 'Descending',
      'Limit': 200,
      'Fields': _favoriteFields,
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<void> addFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.post('/Users/$uid/FavoriteItems/$itemId');
  }

  @override
  Future<void> removeFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client._dio.delete('/Users/$uid/FavoriteItems/$itemId');
  }
}

// ==================== Image ====================

class EmbyImageApi implements ImageApi {
  final EmbyApiClient _client;
  EmbyImageApi(this._client);

  @override
  String getImageUrl({
    required String itemId,
    String? imageTag,
    String imageType = 'Primary',
    int? maxWidth,
    int? maxHeight,
    double quality = 90,
    String? format,
  }) {
    final base = _client._currentLine;
    final buf = StringBuffer('$base/Items/$itemId/Images/$imageType');
    final params = <String, String>{};
    if (maxWidth != null) params['maxWidth'] = maxWidth.toString();
    if (maxHeight != null) params['maxHeight'] = maxHeight.toString();
    params['quality'] = quality.round().toString();
    if (format != null && format.isNotEmpty) params['format'] = format;
    if (_client._authToken != null) params['api_key'] = _client._authToken!;
    if (imageTag != null) params['tag'] = imageTag;
    if (params.isNotEmpty) {
      buf.write('?');
      buf.write(params.entries.map((e) => '${e.key}=${e.value}').join('&'));
    }
    return buf.toString();
  }

  @override
  String getPrimaryImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    return getImageUrl(
        itemId: itemId,
        imageTag: tag,
        imageType: 'Primary',
        maxWidth: maxWidth,
        format: format);
  }

  @override
  String getThumbImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    return getImageUrl(
        itemId: itemId,
        imageTag: tag,
        imageType: 'Thumb',
        maxWidth: maxWidth,
        format: format);
  }

  @override
  String getBackdropImageUrl(String itemId,
      {String? tag, int? maxWidth, String? format}) {
    // 不再强制 maxHeight:450（会把全屏背景图压成低清导致发虚）；
    // 由调用方传入的 maxWidth 决定清晰度，未传时给一个适合背景的默认值。
    return getImageUrl(
      itemId: itemId,
      imageTag: tag,
      imageType: 'Backdrop',
      maxWidth: maxWidth ?? 1280,
      format: format,
    );
  }

  @override
  String? getLogoImageUrl(String itemId, {String? tag, int? maxWidth}) {
    if (tag == null || tag.isEmpty) return null;
    return getImageUrl(
      itemId: itemId,
      imageTag: tag,
      imageType: 'Logo',
      maxWidth: maxWidth ?? 400,
    );
  }
}

// ==================== Danmaku (deprecated - see danmaku/ module) ====================

// ==================== Parse Helpers ====================

String _requireUserId(EmbyApiClient c) {
  final uid = c._userId;
  if (uid == null || uid.isEmpty) {
    // 如果 authToken 存在，使用 "Me" 作为当前用户的别名（Emby API 支持）
    if (c._authToken != null && c._authToken!.isNotEmpty) {
      return 'Me';
    }
    throw Exception('Not authenticated: userId missing');
  }
  return uid;
}

String _currentUserAliasForScopedRequest(EmbyApiClient c) {
  if (c._authToken != null && c._authToken!.isNotEmpty) {
    return 'Me';
  }
  return _requireUserId(c);
}

User _parseUser(Map<String, dynamic> d) {
  return User(
    id: d['Id'] ?? d['UserId'] ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: d['PrimaryImageTag']?.toString(),
    hasPassword: d['HasPassword'] as bool?,
    configuration: (d['Configuration'] as Map<String, dynamic>?)?.keys.toList(),
    policy: _parseUserPolicy(d['Policy']),
  );
}

UserPolicy? _parseUserPolicy(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  bool readBool(String key) => raw[key] as bool? ?? false;
  return UserPolicy(
    isAdministrator: readBool('IsAdministrator'),
    enableContentDownloading: readBool('EnableContentDownloading'),
    // 不同服务端字段差异：Jellyfin 用 EnableContentDownloading，
    // 部分 Emby 版本另有 EnableDownloading / EnableSync。
    enableDownloading:
        readBool('EnableDownloading') || readBool('EnableSync'),
  );
}

ServerInfo _parseServerInfo(Map<String, dynamic> d) {
  return ServerInfo(
    id: d['Id']?.toString() ?? '',
    serverName: d['ServerName'] ?? '',
    version: d['Version'] ?? '',
    productName: d['ProductName']?.toString(),
    operatingSystem: d['OperatingSystem']?.toString(),
  );
}

List<MediaItem> _parseItemList(dynamic data) {
  final d = data as Map<String, dynamic>;
  final items = (d['Items'] ?? d) as List<dynamic>;
  return items.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
}

MediaItem _parseMediaItem(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  final int? childCount = d['ChildCount'] as int?;
  final int? recursiveItemCount = d['RecursiveItemCount'] as int?;
  final people = (d['People'] as List<dynamic>?)
      ?.map((e) => _parsePersonFromItem(e as Map<String, dynamic>))
      .toList();
  final backdrop = _extractBackdrop(d);
  return MediaItem(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    type: d['Type'] ?? '',
    providerIds: _parseProviderIds(d['ProviderIds']),
    presentationUniqueKey: d['PresentationUniqueKey']?.toString(),
    path: d['Path']?.toString(),
    overview: d['Overview']?.toString(),
    primaryImageTag: _extractImageTag(d, 'Primary'),
    thumbImageTag: _extractImageTag(d, 'Thumb'),
    backdropImageTag: backdrop?.tag,
    backdropItemId: backdrop?.itemId,
    communityRating: (d['CommunityRating'] as num?)?.toDouble(),
    officialRating: d['OfficialRating']?.toString(),
    premiereDate: _parseDate(d['PremiereDate']),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    productionYear: d['ProductionYear'] as int?,
    genres: (d['Genres'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    tags: (d['Tags'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    userData: ud != null
        ? UserData(
            playbackPositionTicks:
                _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
            playCount: (ud['PlayCount'] as num?)?.toDouble(),
            unplayedItemCount: (ud['UnplayedItemCount'] as num?)?.toInt(),
          )
        : null,
    seriesName: d['SeriesName']?.toString(),
    indexNumber: d['IndexNumber'] as int?,
    parentIndexNumber: d['ParentIndexNumber'] as int?,
    seriesId: d['SeriesId']?.toString(),
    seasonId: d['SeasonId']?.toString(),
    parentThumbItemId: d['ParentThumbItemId']?.toString(),
    parentThumbImageTag: d['ParentThumbImageTag']?.toString(),
    parentPrimaryImageItemId: d['ParentPrimaryImageItemId']?.toString(),
    parentPrimaryImageTag: d['ParentPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    mediaType: d['MediaType']?.toString(),
    parentId: d['ParentId']?.toString(),
    childCount: recursiveItemCount ?? childCount,
    recursiveItemCount: recursiveItemCount,
    people: people,
    canDownload: d['CanDownload'] as bool? ?? d['SupportsSync'] as bool?,
    remoteTrailers: (d['RemoteTrailers'] as List<dynamic>?)
        ?.map((e) {
          if (e is Map<String, dynamic>) {
            return e['Url']?.toString() ?? e['url']?.toString();
          }
          return e?.toString();
        })
        .where((url) => url != null && url.isNotEmpty)
        .cast<String>()
        .toList(),
    logoItemId: _extractLogoItemId(d),
    logoImageTag: _extractLogoImageTag(d),
  );
}

Map<String, String>? _parseProviderIds(dynamic value) {
  if (value is! Map) {
    return null;
  }
  final providerIds = <String, String>{};
  value.forEach((key, entryValue) {
    final normalizedKey = key?.toString();
    final normalizedValue = entryValue?.toString();
    if (normalizedKey == null ||
        normalizedKey.isEmpty ||
        normalizedValue == null ||
        normalizedValue.isEmpty) {
      return;
    }
    providerIds[normalizedKey] = normalizedValue;
  });
  if (providerIds.isEmpty) {
    return null;
  }
  return providerIds;
}

String? _extractImageTag(Map<String, dynamic> d, String type) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  final value = tags?[type]?.toString();
  if (value == null || value.isEmpty) return null;
  return value;
}

/// 背景图（Backdrop）来源。
///
/// Emby 的背景图**不在** `ImageTags` 里，而在独立的 `BackdropImageTags` 数组；
/// 剧集/季等自身没有背景图时，Emby 通过 `ParentBackdropImageTags` +
/// `ParentBackdropItemId` 提供父级（剧集）的背景图。
/// 之前误读 `ImageTags['Backdrop']` 导致背景图恒为 null、详情页退回封面图。
class _BackdropRef {
  final String tag;
  final String itemId;
  const _BackdropRef(this.tag, this.itemId);
}

_BackdropRef? _extractBackdrop(Map<String, dynamic> d) {
  String? firstTag(dynamic list) {
    if (list is List) {
      for (final e in list) {
        final tag = e?.toString();
        if (tag != null && tag.isNotEmpty) return tag;
      }
    }
    return null;
  }

  // 自身背景图
  final ownTag = firstTag(d['BackdropImageTags']);
  final ownId = d['Id']?.toString();
  if (ownTag != null && ownId != null && ownId.isNotEmpty) {
    return _BackdropRef(ownTag, ownId);
  }

  // 回退：父级（剧集）背景图
  final parentTag = firstTag(d['ParentBackdropImageTags']);
  final parentId = d['ParentBackdropItemId']?.toString();
  if (parentTag != null && parentId != null && parentId.isNotEmpty) {
    return _BackdropRef(parentTag, parentId);
  }

  return null;
}

/// 提取 Logo 项目 ID：优先使用自身，否则使用父级
String? _extractLogoItemId(Map<String, dynamic> d) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  if (tags?.containsKey('Logo') == true) {
    return d['Id']?.toString();
  }
  final parentId = d['ParentLogoItemId']?.toString();
  return (parentId != null && parentId.isNotEmpty) ? parentId : null;
}

/// 提取 Logo 缓存 tag：优先使用自身，否则使用父级
String? _extractLogoImageTag(Map<String, dynamic> d) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  final ownTag = tags?['Logo']?.toString();
  if (ownTag != null && ownTag.isNotEmpty) return ownTag;
  final parentTag = d['ParentLogoImageTag']?.toString();
  return (parentTag != null && parentTag.isNotEmpty) ? parentTag : null;
}

int? _parseTicks(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

double? _parseTicksDouble(dynamic v) {
  final t = _parseTicks(v);
  return t?.toDouble();
}

/// 网盘/前后端分离服可能把数值字段以 double 或字符串下发,直接 `as int?` 会抛
/// 类型异常并连累整个 PlaybackInfo 解析失败 → 详情页音频/字幕/版本/线路选择整块空白。
int? _asInt(dynamic v) => _parseTicks(v);

bool? _asBool(dynamic v) {
  if (v == null || v is bool) return v as bool?;
  final s = v.toString().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return null;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

Library _parseLibrary(Map<String, dynamic> d) {
  return Library(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: _extractImageTag(d, 'Primary'),
    collectionType: d['CollectionType']?.toString() ?? 'mixed',
  );
}

Season _parseSeason(Map<String, dynamic> d, String seriesId) {
  return Season(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag: _extractImageTag(d, 'Primary'),
    thumbImageTag: _extractImageTag(d, 'Thumb'),
    seriesId: d['SeriesId']?.toString() ?? seriesId,
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
  );
}

Episode _parseEpisode(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  // 首个 MediaSource：取视频流分辨率 + 源总码率（缺失回退视频流码率），供选集列表展示。
  String? videoResolution;
  int? videoBitRate;
  final sources = d['MediaSources'] as List<dynamic>?;
  if (sources != null && sources.isNotEmpty) {
    final source = _parseMediaSource(sources.first as Map<String, dynamic>);
    videoResolution = source.primaryVideoStream?.resolution;
    if (videoResolution != null && videoResolution.isEmpty) videoResolution = null;
    videoBitRate = _asInt((sources.first as Map<String, dynamic>)['Bitrate']) ??
        source.primaryVideoStream?.bitRate;
  }
  return Episode(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag:
        _extractImageTag(d, 'Primary') ?? d['PrimaryImageTag']?.toString(),
    thumbImageTag:
        _extractImageTag(d, 'Thumb') ?? d['ThumbImageTag']?.toString(),
    seriesId: d['SeriesId']?.toString() ?? '',
    seasonId: d['SeasonId']?.toString() ?? '',
    parentThumbItemId: d['ParentThumbItemId']?.toString(),
    parentThumbImageTag: d['ParentThumbImageTag']?.toString(),
    parentPrimaryImageItemId: d['ParentPrimaryImageItemId']?.toString(),
    parentPrimaryImageTag: d['ParentPrimaryImageTag']?.toString(),
    seriesThumbImageTag: d['SeriesThumbImageTag']?.toString(),
    seriesPrimaryImageTag: d['SeriesPrimaryImageTag']?.toString(),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    userData: ud != null
        ? UserData(
            playbackPositionTicks:
                _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
          )
        : null,
    overview: d['Overview']?.toString(),
    videoResolution: videoResolution,
    videoBitRate: videoBitRate,
  );
}

Person _parsePersonFromItem(Map<String, dynamic> d) {
  return Person(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag:
        _extractImageTag(d, 'Primary') ?? d['PrimaryImageTag']?.toString(),
    role: d['Role']?.toString(),
    type: d['Type']?.toString(),
  );
}

PlaybackInfo _parsePlaybackInfo(Map<String, dynamic> d, String itemId) {
  final sources = (d['MediaSources'] as List<dynamic>?) ?? [];
  return PlaybackInfo(
    itemId: d['ItemId']?.toString() ?? itemId,
    mediaSources: sources
        .map((e) => _parseMediaSource(e as Map<String, dynamic>))
        .toList(),
  );
}

MediaSource _parseMediaSource(Map<String, dynamic> d) {
  final streams = (d['MediaStreams'] as List<dynamic>?) ?? [];
  return MediaSource(
    id: d['Id']?.toString() ?? '',
    name: d['Name']?.toString(),
    path: d['Path']?.toString(),
    container: d['Container']?.toString(),
    size: _asInt(d['Size']),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    protocol: d['Protocol']?.toString(),
    isRemote: _asBool(d['IsRemote']),
    mediaStreams: streams
        .map((e) => _parseMediaStream(e as Map<String, dynamic>))
        .toList(),
  );
}

MediaStream _parseMediaStream(Map<String, dynamic> d) {
  return MediaStream(
    index: _asInt(d['Index']) ?? 0,
    type: d['Type'] ?? '',
    codec: d['Codec']?.toString(),
    language: d['Language']?.toString(),
    title: d['Title']?.toString(),
    isDefault: _asBool(d['IsDefault']),
    isExternal: _asBool(d['IsExternal']),
    displayTitle: d['DisplayTitle']?.toString(),
    path: d['Path']?.toString(),
    deliveryUrl: d['DeliveryUrl']?.toString(),
    deliveryMethod: d['DeliveryMethod']?.toString(),
    isExternalUrl: _asBool(d['IsExternalUrl']),
    videoCodec: d['VideoCodec']?.toString() ?? d['Codec']?.toString(),
    width: _asInt(d['Width']),
    height: _asInt(d['Height']),
    channels: _asInt(d['Channels']),
    bitRate: _asInt(d['BitRate']),
    videoRange: d['VideoRange']?.toString(),
    videoRangeType: d['VideoRangeType']?.toString(),
  );
}
