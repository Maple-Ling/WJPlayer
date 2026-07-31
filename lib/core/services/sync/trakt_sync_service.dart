import 'package:dio/dio.dart';

import '../app_logger.dart';
import 'calendar_models.dart';
import 'obfuscated_secrets.dart';
import 'sync_config.dart';
import 'sync_models.dart';

/// Trakt 设备码流程返回的待授权信息。
class TraktDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int interval; // 轮询间隔（秒）
  final int expiresIn; // 有效期（秒）

  const TraktDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
    required this.expiresIn,
  });
}

/// 设备码轮询的结果状态。
enum TraktPollState { pending, slowDown, authorized, expired, denied, error }

/// Scrobble 动作：start=开始观看（Trakt 显示「正在观看」），pause=暂停，
/// stop=停止。Trakt 在 stop 且 progress≥80% 时自动标记看过并写入历史，
/// <80% 则存为续播点（/sync/playback），供跨设备续播。
enum TraktScrobbleAction { start, pause, stop }

class TraktPollResult {
  final TraktPollState state;
  final SyncAccount? account;
  const TraktPollResult(this.state, [this.account]);
}

/// Trakt 同步内核：设备码登录 + 令牌刷新 + 观看记录写入。
///
/// 设备码流程对三端（PC/移动/TV）一致：App 展示 verification_url 与 user_code，
/// 用户在任意浏览器授权，App 轮询直到拿到令牌；TV 无需输入账号密码。
class TraktSyncService {
  static final _logger = AppLogger();
  static const String _apiBase = 'https://api.trakt.tv';
  // 设备码流程不使用真实回调地址，刷新令牌时按文档要求回填占位值。
  static const String _oobRedirect = 'urn:ietf:wg:oauth:2.0:oob';

  final Dio _dio;

  TraktSyncService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _apiBase,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': kSyncUserAgent,
                'trakt-api-version': '2',
                'trakt-api-key': ObfuscatedSecrets.traktClientId,
              },
              // 我们自行处理 4xx 状态码（设备码轮询依赖 400/409/410/418/429）。
              validateStatus: (_) => true,
            ));

  Map<String, String> _authHeaders(String accessToken) => {
        'Authorization': 'Bearer $accessToken',
        'trakt-api-version': '2',
        'trakt-api-key': ObfuscatedSecrets.traktClientId,
      };

  /// 第一步：申请设备码。
  Future<TraktDeviceCode> requestDeviceCode() async {
    final resp = kUseSyncProxy
        ? await _dio.post(
            '$kSyncProxyBaseUrl/trakt/device',
            options: Options(headers: syncProxyHeaders()),
          )
        : await _dio.post(
            '/oauth/device/code',
            data: {'client_id': ObfuscatedSecrets.traktClientId},
          );
    final code = resp.statusCode ?? 0;
    if (code < 200 || code >= 300 || resp.data is! Map) {
      throw StateError('Trakt 申请设备码失败: HTTP $code ${resp.data}');
    }
    final data = resp.data as Map;
    return TraktDeviceCode(
      deviceCode: data['device_code'].toString(),
      userCode: data['user_code'].toString(),
      verificationUrl: data['verification_url'].toString(),
      interval: (data['interval'] as num?)?.toInt() ?? 5,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 600,
    );
  }

  /// 第二步：轮询一次，看用户是否已授权。
  Future<TraktPollResult> pollOnce(String deviceCode) async {
    try {
      final resp = kUseSyncProxy
          ? await _dio.post(
              '$kSyncProxyBaseUrl/trakt/token',
              data: {'device_code': deviceCode},
              options: Options(headers: syncProxyHeaders()),
            )
          : await _dio.post(
              '/oauth/device/token',
              data: {
                'code': deviceCode,
                'client_id': ObfuscatedSecrets.traktClientId,
                'client_secret': ObfuscatedSecrets.traktClientSecret,
              },
            );
      switch (resp.statusCode) {
        case 200:
          final account = await _accountFromToken(resp.data as Map);
          return TraktPollResult(TraktPollState.authorized, account);
        case 400: // 仍在等待用户授权
          return const TraktPollResult(TraktPollState.pending);
        case 429: // 轮询过快
          return const TraktPollResult(TraktPollState.slowDown);
        case 404: // 无效 device_code
        case 410: // 已过期
          return const TraktPollResult(TraktPollState.expired);
        case 409: // 已被使用
          return const TraktPollResult(TraktPollState.expired);
        case 418: // 用户拒绝
          return const TraktPollResult(TraktPollState.denied);
        default:
          _logger.w('TraktSync', '设备码轮询异常状态: ${resp.statusCode} ${resp.data}');
          return const TraktPollResult(TraktPollState.error);
      }
    } catch (e) {
      _logger.w('TraktSync', '设备码轮询失败: $e');
      return const TraktPollResult(TraktPollState.error);
    }
  }

  /// 用 refresh_token 换新令牌。失败返回 null（通常意味着需要重新登录）。
  Future<SyncAccount?> refresh(SyncAccount account) async {
    final refreshToken = account.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    try {
      final resp = kUseSyncProxy
          ? await _dio.post(
              '$kSyncProxyBaseUrl/trakt/refresh',
              data: {'refresh_token': refreshToken},
              options: Options(headers: syncProxyHeaders()),
            )
          : await _dio.post(
              '/oauth/token',
              data: {
                'refresh_token': refreshToken,
                'client_id': ObfuscatedSecrets.traktClientId,
                'client_secret': ObfuscatedSecrets.traktClientSecret,
                'redirect_uri': _oobRedirect,
                'grant_type': 'refresh_token',
              },
            );
      final code = resp.statusCode ?? 0;
      if (code < 200 || code >= 300 || resp.data is! Map) {
        _logger.w('TraktSync', '刷新令牌失败: HTTP $code');
        return null;
      }
      return _accountFromToken(resp.data as Map, fallback: account);
    } catch (e) {
      _logger.w('TraktSync', '刷新令牌异常: $e');
      return null;
    }
  }

  /// 确保令牌有效：过期则刷新。返回可用账号或 null（需重新登录）。
  Future<SyncAccount?> ensureValid(SyncAccount account) async {
    if (!account.isExpired) return account;
    return refresh(account);
  }

  SyncAccount _buildAccount(Map token, {SyncAccount? fallback}) {
    final access = token['access_token']?.toString() ?? fallback?.accessToken;
    final createdAt = (token['created_at'] as num?)?.toInt();
    final expiresIn = (token['expires_in'] as num?)?.toInt();
    DateTime? expiresAt;
    if (createdAt != null && expiresIn != null) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
          .add(Duration(seconds: expiresIn));
    } else if (expiresIn != null) {
      expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    }
    return SyncAccount(
      service: SyncService.trakt,
      accessToken: access ?? '',
      refreshToken:
          token['refresh_token']?.toString() ?? fallback?.refreshToken,
      expiresAt: expiresAt ?? fallback?.expiresAt,
      username: fallback?.username,
      userId: fallback?.userId,
    );
  }

  /// 由令牌响应构造账号，并尝试补全用户名。
  Future<SyncAccount> _accountFromToken(Map token,
      {SyncAccount? fallback}) async {
    var account = _buildAccount(token, fallback: fallback);
    if (account.username == null && account.accessToken.isNotEmpty) {
      final profile = await _fetchProfile(account.accessToken);
      if (profile != null) {
        account = account.copyWith(
          username: profile.$1,
          userId: profile.$2,
        );
      }
    }
    return account;
  }

  /// 拉取当前用户资料，返回 (username, userId)。
  Future<(String?, String?)?> _fetchProfile(String accessToken) async {
    try {
      final resp = await _dio.get(
        '/users/me',
        options: Options(headers: _authHeaders(accessToken)),
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final data = resp.data as Map;
        final ids = data['ids'];
        final userId = ids is Map ? ids['slug']?.toString() : null;
        return (data['username']?.toString(), userId);
      }
    } catch (e) {
      _logger.w('TraktSync', '获取用户资料失败: $e');
    }
    return null;
  }

  /// Scrobble 一次（start/pause/stop）。这是 Trakt 官方设计的实时观看机制：
  /// start 时账号显示「正在观看」，stop 时 Trakt 按 [progress] 自动判定看过/续播点。
  ///
  /// [ids] 为外部 ID 映射，如 {'imdb': 'tt...', 'tmdb': 12345}；
  /// [type] 为 'movie' 或 'episode'（episode 需 tvdb/tmdb/imdb 等）；
  /// [progress] 为 0~100 的百分比。
  Future<bool> scrobble({
    required String type,
    required Map<String, dynamic> ids,
    required double progress,
    required TraktScrobbleAction action,
  }) async {
    final account = SyncSession.current(SyncService.trakt);
    if (account == null) return false;
    final valid = await ensureValid(account);
    if (valid == null) return false;

    final body = {
      type: {'ids': ids},
      'progress': progress.clamp(0, 100),
    };
    try {
      final resp = await _dio.post(
        '/scrobble/${action.name}',
        data: body,
        options: Options(headers: _authHeaders(valid.accessToken)),
      );
      final code = resp.statusCode ?? 0;
      // 409 = 已有进行中的 scrobble（重复 start），对播放器而言视作成功。
      final ok = (code >= 200 && code < 300) || code == 409;
      if (!ok) {
        _logger.w('TraktSync',
            'scrobble ${action.name} 失败: HTTP $code ${resp.data}');
      }
      return ok;
    } catch (e) {
      _logger.w('TraktSync', 'scrobble ${action.name} 异常: $e');
      return false;
    }
  }

  /// 拉取追剧日历：从 [startOffsetDays] 天前起、共 [days] 天内的剧集放送。
  /// [onlyMine] 为 true 只看我追的（/calendars/my），false 显示全部放送（/calendars/all）。
  /// 需已连接 Trakt；未连接/失败返回空列表。
  Future<List<CalendarEntry>> fetchShowsCalendar({
    int startOffsetDays = 3,
    int days = 21,
    bool onlyMine = true,
  }) async {
    final account = SyncSession.current(SyncService.trakt);
    if (account == null) return const [];
    final valid = await ensureValid(account);
    if (valid == null) return const [];
    final start = DateTime.now().subtract(Duration(days: startOffsetDays));
    final startStr = '${start.year.toString().padLeft(4, '0')}-'
        '${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';
    // /calendars/all 是「全站放送」火喉，量极大——截断防止列表爆炸。
    const allCap = 200;
    final scope = onlyMine ? 'my' : 'all';
    try {
      final resp = await _dio.get(
        '/calendars/$scope/shows/$startStr/$days',
        options: Options(headers: _authHeaders(valid.accessToken)),
      );
      if ((resp.statusCode ?? 0) != 200 || resp.data is! List) {
        _logger.w('TraktSync', '追剧日历失败: HTTP ${resp.statusCode}');
        return const [];
      }
      final out = <CalendarEntry>[];
      for (final raw in resp.data as List) {
        if (!onlyMine && out.length >= allCap) break;
        if (raw is! Map) continue;
        final show = raw['show'];
        final ep = raw['episode'];
        final title =
            (show is Map ? show['title']?.toString() : null) ?? '未知剧集';
        final ids = show is Map ? show['ids'] : null;
        final tmdbId = ids is Map ? (ids['tmdb'] as num?)?.toInt() : null;
        final airedRaw = raw['first_aired']?.toString();
        final aired =
            airedRaw != null ? DateTime.tryParse(airedRaw)?.toLocal() : null;
        String? sub;
        if (ep is Map) {
          final s = (ep['season'] as num?)?.toInt();
          final n = (ep['number'] as num?)?.toInt();
          final epTitle = ep['title']?.toString();
          final code = (s != null && n != null)
              ? 'S${s.toString().padLeft(2, '0')}E${n.toString().padLeft(2, '0')}'
              : null;
          final parts = [code, epTitle]
              .where((e) => e != null && e.isNotEmpty)
              .join(' · ');
          sub = parts.isEmpty ? null : parts;
        }
        out.add(CalendarEntry(
          title: title,
          subtitle: sub,
          airDate: aired,
          tmdbId: tmdbId,
          source: SyncService.trakt,
        ));
      }
      return out;
    } catch (e) {
      _logger.w('TraktSync', '追剧日历异常: $e');
      return const [];
    }
  }
}

/// 当前已连接账号的轻量访问入口，避免 service 直接依赖 Riverpod。
/// 由 [SyncController] 在状态变更时回填。
class SyncSession {
  SyncSession._();
  static final Map<SyncService, SyncAccount> _accounts = {};

  static SyncAccount? current(SyncService service) => _accounts[service];

  static void set(SyncService service, SyncAccount? account) {
    if (account == null) {
      _accounts.remove(service);
    } else {
      _accounts[service] = account;
    }
  }
}
