import 'package:dio/dio.dart';

import '../app_logger.dart';
import 'calendar_models.dart';
import 'obfuscated_secrets.dart';
import 'sync_config.dart';
import 'sync_models.dart';
import 'trakt_sync_service.dart' show SyncSession;

/// Bangumi 回调地址默认值。
///
/// Bangumi OAuth 不支持设备码/oob，必须使用真实回调。本项目用「显示授权码」
/// 的静态页（见 docs/oauth/bangumi.html，可托管到 GitHub Pages）。
/// 用户在设置页可改成自己托管的地址；务必与 Bangumi 应用后台登记的回调一致。
const String kDefaultBangumiRedirectUri =
    'https://291277.xyz/oauth/bangumi';

/// Bangumi 同步内核：授权码（手动粘贴）登录 + 令牌刷新 + 收藏/进度写入。
class BangumiSyncService {
  static final _logger = AppLogger();
  static const String _oauthBase = 'https://bgm.tv';
  // 国内加速反代开关生效点（默认反代，可在设置里切回官方）。见 sync_config.dart。
  String get _apiBase => bangumiApiBase;

  final Dio _dio;

  BangumiSyncService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': kSyncUserAgent},
              validateStatus: (_) => true,
            ));

  /// 构造授权页 URL，用户在浏览器打开并授权。
  String buildAuthorizeUrl({required String redirectUri}) {
    final params = {
      'client_id': ObfuscatedSecrets.bangumiAppId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
    };
    final query = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    // 授权页跟随反代开关（免梯子登录）；换 token 仍走 CF proxy / 官方，见 exchangeCode。
    return '$bangumiAuthorizeBase/oauth/authorize?$query';
  }

  /// 用粘贴回来的授权码换取令牌。
  Future<SyncAccount> exchangeCode({
    required String code,
    required String redirectUri,
  }) async {
    final resp = kUseSyncProxy
        ? await _dio.post(
            '$kSyncProxyBaseUrl/bangumi/token',
            data: {'code': code.trim(), 'redirect_uri': redirectUri},
            options: Options(headers: syncProxyHeaders()),
          )
        : await _dio.post(
            '$_oauthBase/oauth/access_token',
            data: {
              'grant_type': 'authorization_code',
              'client_id': ObfuscatedSecrets.bangumiAppId,
              'client_secret': ObfuscatedSecrets.bangumiAppSecret,
              'code': code.trim(),
              'redirect_uri': redirectUri,
            },
            options: Options(contentType: Headers.formUrlEncodedContentType),
          );
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300 || resp.data is! Map) {
      throw StateError('Bangumi 令牌交换失败: HTTP $status ${resp.data}');
    }
    return _accountFromToken(resp.data as Map);
  }

  /// 刷新令牌。失败返回 null（需重新登录）。
  Future<SyncAccount?> refresh(SyncAccount account, {String? redirectUri}) async {
    final refreshToken = account.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    final effectiveRedirect = redirectUri ?? kDefaultBangumiRedirectUri;
    try {
      final resp = kUseSyncProxy
          ? await _dio.post(
              '$kSyncProxyBaseUrl/bangumi/refresh',
              data: {
                'refresh_token': refreshToken,
                'redirect_uri': effectiveRedirect,
              },
              options: Options(headers: syncProxyHeaders()),
            )
          : await _dio.post(
              '$_oauthBase/oauth/access_token',
              data: {
                'grant_type': 'refresh_token',
                'client_id': ObfuscatedSecrets.bangumiAppId,
                'client_secret': ObfuscatedSecrets.bangumiAppSecret,
                'refresh_token': refreshToken,
                'redirect_uri': effectiveRedirect,
              },
              options: Options(contentType: Headers.formUrlEncodedContentType),
            );
      final status = resp.statusCode ?? 0;
      if (status < 200 || status >= 300 || resp.data is! Map) {
        _logger.w('BangumiSync', '刷新令牌失败: HTTP $status');
        return null;
      }
      return _accountFromToken(resp.data as Map, fallback: account);
    } catch (e) {
      _logger.w('BangumiSync', '刷新令牌异常: $e');
      return null;
    }
  }

  /// 确保令牌有效：过期则刷新。
  Future<SyncAccount?> ensureValid(SyncAccount account) async {
    if (!account.isExpired) return account;
    return refresh(account);
  }

  SyncAccount _buildAccount(Map token, {SyncAccount? fallback}) {
    final access = token['access_token']?.toString() ?? fallback?.accessToken;
    final expiresIn = (token['expires_in'] as num?)?.toInt();
    final expiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : fallback?.expiresAt;
    return SyncAccount(
      service: SyncService.bangumi,
      accessToken: access ?? '',
      refreshToken:
          token['refresh_token']?.toString() ?? fallback?.refreshToken,
      expiresAt: expiresAt,
      username: fallback?.username,
      userId: token['user_id']?.toString() ?? fallback?.userId,
    );
  }

  Future<SyncAccount> _accountFromToken(Map token,
      {SyncAccount? fallback}) async {
    var account = _buildAccount(token, fallback: fallback);
    if (account.accessToken.isNotEmpty && account.username == null) {
      final profile = await _fetchProfile(account.accessToken);
      if (profile != null) {
        account = account.copyWith(
          username: profile.$1,
          userId: account.userId ?? profile.$2,
        );
      }
    }
    return account;
  }

  /// 拉取当前用户资料，返回 (username/nickname, userId)。
  Future<(String?, String?)?> _fetchProfile(String accessToken) async {
    try {
      final resp = await _dio.get(
        '$_apiBase/v0/me',
        options: Options(headers: {
          'Authorization': 'Bearer $accessToken',
          'User-Agent': kSyncUserAgent,
        }),
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final data = resp.data as Map;
        final name = data['nickname']?.toString() ?? data['username']?.toString();
        return (name, data['id']?.toString());
      }
    } catch (e) {
      _logger.w('BangumiSync', '获取用户资料失败: $e');
    }
    return null;
  }

  /// 设置条目收藏状态（type: 1=想看 2=看过 3=在看 4=搁置 5=抛弃）。
  ///
  /// 更新单集进度前必须先确保条目已被收藏，否则「未收藏的番」更新单集会失败——
  /// 这是把「看过」正确同步到 Bangumi 的前提，同时给账号带上「在看」状态。
  Future<bool> setCollectionType({
    required int subjectId,
    required int type,
  }) async {
    final account = SyncSession.current(SyncService.bangumi);
    if (account == null) return false;
    final valid = await ensureValid(account);
    if (valid == null) return false;
    try {
      final resp = await _dio.post(
        '$_apiBase/v0/users/-/collections/$subjectId',
        data: {'type': type},
        options: Options(headers: {
          'Authorization': 'Bearer ${valid.accessToken}',
          'User-Agent': kSyncUserAgent,
          'Content-Type': 'application/json',
        }),
      );
      final ok = (resp.statusCode ?? 0) >= 200 && (resp.statusCode ?? 0) < 300;
      if (!ok) {
        _logger.w('BangumiSync',
            '设置收藏状态失败: HTTP ${resp.statusCode} ${resp.data}');
      }
      return ok;
    } catch (e) {
      _logger.w('BangumiSync', '设置收藏状态异常: $e');
      return false;
    }
  }

  /// 更新单集观看状态（type: 2=看过）。供播放器集成阶段调用。
  Future<bool> updateEpisodeStatus({
    required int subjectId,
    required int episodeId,
    int type = 2,
  }) async {
    final account = SyncSession.current(SyncService.bangumi);
    if (account == null) return false;
    final valid = await ensureValid(account);
    if (valid == null) return false;
    try {
      final resp = await _dio.put(
        '$_apiBase/v0/users/-/collections/$subjectId/episodes/$episodeId',
        data: {'type': type},
        options: Options(headers: {
          'Authorization': 'Bearer ${valid.accessToken}',
          'User-Agent': kSyncUserAgent,
          'Content-Type': 'application/json',
        }),
      );
      final ok = (resp.statusCode ?? 0) >= 200 && (resp.statusCode ?? 0) < 300;
      if (!ok) {
        _logger.w('BangumiSync',
            '更新单集状态失败: HTTP ${resp.statusCode} ${resp.data}');
      }
      return ok;
    } catch (e) {
      _logger.w('BangumiSync', '更新单集状态异常: $e');
      return false;
    }
  }

  /// 拉取「追番日历」：当季放送表，按每周放送日（1=周一…7=周日）归组。
  /// [onlyMine] 为 true 时只保留我在看的番，false 显示整季全部。
  ///
  /// ponytail: Bangumi 无「用户下一集放送时间」接口，这里用全站当季放送表
  ///           (/calendar)——只覆盖「当季正在放送」的番，已完结的在看番不会
  ///           出现。够用；要精确到每一集，再逐条查 subject 的 episodes。
  Future<List<CalendarEntry>> fetchAnimeCalendar({bool onlyMine = true}) async {
    final account = SyncSession.current(SyncService.bangumi);
    if (account == null) return const [];
    final valid = await ensureValid(account);
    if (valid == null) return const [];
    final auth = {
      'Authorization': 'Bearer ${valid.accessToken}',
      'User-Agent': kSyncUserAgent,
    };
    try {
      // 1) 只看我追的：先取在看动画的 subject id 集合。
      final watching = <int>{};
      if (onlyMine) {
        final col = await _dio.get(
          '$_apiBase/v0/users/-/collections',
          queryParameters: {'subject_type': 2, 'type': 3, 'limit': 50},
          options: Options(headers: auth),
        );
        if ((col.statusCode ?? 0) == 200 && col.data is Map) {
          for (final it in (col.data['data'] as List? ?? const [])) {
            final id = it is Map ? (it['subject_id'] as num?)?.toInt() : null;
            if (id != null) watching.add(id);
          }
        }
        if (watching.isEmpty) return const [];
      }
      // 2) 当季放送表（onlyMine 时过滤出在看的）。
      final cal = await _dio.get('$_apiBase/calendar',
          options: Options(headers: {'User-Agent': kSyncUserAgent}));
      if ((cal.statusCode ?? 0) != 200 || cal.data is! List) return const [];
      final out = <CalendarEntry>[];
      for (final group in cal.data as List) {
        if (group is! Map) continue;
        final weekday = (group['weekday'] is Map)
            ? (group['weekday']['id'] as num?)?.toInt()
            : null;
        for (final item in (group['items'] as List? ?? const [])) {
          if (item is! Map) continue;
          final id = (item['id'] as num?)?.toInt();
          if (id == null) continue;
          if (onlyMine && !watching.contains(id)) continue;
          final nameCn = item['name_cn']?.toString();
          final title = (nameCn != null && nameCn.isNotEmpty)
              ? nameCn
              : (item['name']?.toString() ?? '未知番剧');
          final images = item['images'];
          final img = images is Map
              ? (images['common'] ?? images['medium'] ?? images['large'])
                  ?.toString()
              : null;
          final rating = item['rating'] is Map
              ? (item['rating']['score'] as num?)
              : null;
          out.add(CalendarEntry(
            title: title,
            subtitle: rating != null ? '评分 $rating' : null,
            weekday: weekday,
            imageUrl: img,
            source: SyncService.bangumi,
          ));
        }
      }
      return out;
    } catch (e) {
      _logger.w('BangumiSync', '追番日历异常: $e');
      return const [];
    }
  }
}
