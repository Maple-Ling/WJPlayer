import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_preferences.dart';
import '../services/sync/sync_config.dart' show kBangumiMirrorPrefKey;
import '../api/api_interfaces.dart' show MediaItem;
import '../api/danmaku/danmaku_service.dart';
import '../services/sync/bangumi_sync_service.dart';
import '../services/sync/calendar_models.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/sync_scrobble_service.dart';
import '../services/sync/sync_secure_store.dart';
import '../services/sync/trakt_sync_service.dart';
import '../services/tmdb_image_service.dart';

/// 同步功能的全局状态：每个服务的已连接账号 + Bangumi 回调地址。
class SyncState {
  final SyncAccount? trakt;
  final SyncAccount? bangumi;
  final String bangumiRedirectUri;

  const SyncState({
    this.trakt,
    this.bangumi,
    required this.bangumiRedirectUri,
  });

  SyncAccount? account(SyncService service) {
    switch (service) {
      case SyncService.trakt:
        return trakt;
      case SyncService.bangumi:
        return bangumi;
    }
  }

  bool isConnected(SyncService service) => account(service) != null;

  SyncState copyWith({
    SyncAccount? trakt,
    SyncAccount? bangumi,
    String? bangumiRedirectUri,
    bool clearTrakt = false,
    bool clearBangumi = false,
  }) {
    return SyncState(
      trakt: clearTrakt ? null : (trakt ?? this.trakt),
      bangumi: clearBangumi ? null : (bangumi ?? this.bangumi),
      bangumiRedirectUri: bangumiRedirectUri ?? this.bangumiRedirectUri,
    );
  }
}

const String _bangumiRedirectPrefKey = 'bangumi_redirect_uri';

/// Bangumi 国内加速反代开关（默认开）。开=走 bgmapi/bgmimg.anibt.net 反代，
/// 关=直连官方 api.bgm.tv。生效点在 sync_config.dart 的 [bangumiApiBase]。
final bangumiMirrorProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool(kBangumiMirrorPrefKey),
    writeValue: (prefs, value) async {
      await prefs.setBool(kBangumiMirrorPrefKey, value);
    },
  );
});

class SyncController extends StateNotifier<SyncState> {
  SyncController(this._ref)
      : super(SyncState(
          bangumiRedirectUri:
              AppPreferencesStore.instance.getString(_bangumiRedirectPrefKey) ??
                  kDefaultBangumiRedirectUri,
        )) {
    _restore();
  }

  final Ref _ref;

  final TraktSyncService trakt = TraktSyncService();
  final BangumiSyncService bangumi = BangumiSyncService();
  late final SyncScrobbleService _scrobble =
      SyncScrobbleService(trakt: trakt, bangumi: bangumi);

  /// 启动时从存储恢复账号，并回填到 [SyncSession]（供 service 层调用）。
  void _restore() {
    final t = SyncSecureStore.read(SyncService.trakt);
    final b = SyncSecureStore.read(SyncService.bangumi);
    SyncSession.set(SyncService.trakt, t);
    SyncSession.set(SyncService.bangumi, b);
    state = state.copyWith(trakt: t, bangumi: b);
  }

  Future<void> _persist(SyncAccount account) async {
    await SyncSecureStore.write(account);
    SyncSession.set(account.service, account);
  }

  // ---- Trakt 设备码流程 ----

  Future<TraktDeviceCode> startTraktDeviceAuth() {
    return trakt.requestDeviceCode();
  }

  /// 轮询一次；授权成功时落盘并更新状态。
  Future<TraktPollResult> pollTrakt(String deviceCode) async {
    final result = await trakt.pollOnce(deviceCode);
    if (result.state == TraktPollState.authorized && result.account != null) {
      await _persist(result.account!);
      state = state.copyWith(trakt: result.account);
    }
    return result;
  }

  // ---- Bangumi 授权码流程 ----

  String buildBangumiAuthorizeUrl() {
    return bangumi.buildAuthorizeUrl(redirectUri: state.bangumiRedirectUri);
  }

  Future<void> setBangumiRedirectUri(String uri) async {
    final trimmed = uri.trim();
    if (trimmed.isEmpty) return;
    await AppPreferencesStore.instance
        .setString(_bangumiRedirectPrefKey, trimmed);
    state = state.copyWith(bangumiRedirectUri: trimmed);
  }

  /// 用粘贴的授权码完成登录；成功落盘并更新状态。
  Future<void> connectBangumiWithCode(String code) async {
    final account = await bangumi.exchangeCode(
      code: code,
      redirectUri: state.bangumiRedirectUri,
    );
    await _persist(account);
    state = state.copyWith(bangumi: account);
  }

  // ---- 观看记录自动同步 ----

  /// 起播时调用：给 Trakt 发 scrobble/start，账号显示「正在观看」。
  /// [progress] 为起播位置的百分比（续播时非 0）。未连 Trakt 时不产生请求。
  Future<void> scrobbleStart(MediaItem item, {double progress = 0}) async {
    if (!state.isConnected(SyncService.trakt)) return;
    await _scrobble.traktScrobble(item, TraktScrobbleAction.start, progress);
  }

  /// 播放停止时调用：Trakt 总是发 scrobble/stop（按 [progress] 自动判定看过/续播点）；
  /// Bangumi 仅在 [reachedThreshold] 时标记「在看 + 单集看过」。
  /// 未连接任何服务时直接返回，不产生网络请求。
  Future<void> scrobbleStop(
    MediaItem item, {
    required double progress,
    required bool reachedThreshold,
    Map<String, String>? seriesProviderIds,
  }) async {
    if (!state.isConnected(SyncService.trakt) &&
        !state.isConnected(SyncService.bangumi)) {
      return;
    }
    // 弹弹play 在线时作为 Bangumi 反查首选（需配置 DANDANPLAY 凭据，与弹幕同一套）。
    final dandanplay = _ref.read(danmakuServiceProvider).dandanplay;
    await _scrobble.scrobbleStop(
      item,
      progress: progress,
      reachedThreshold: reachedThreshold,
      seriesProviderIds: seriesProviderIds,
      dandanplay: dandanplay,
    );
  }

  // ---- 追剧日历 ----

  /// 按来源拉取追剧日历；[onlyMine] 为 true 只看我追的，false 显示整季全部。
  /// 未连接对应服务时返回空列表。
  Future<List<CalendarEntry>> fetchCalendar(
    SyncService source, {
    bool onlyMine = true,
  }) {
    switch (source) {
      case SyncService.trakt:
        return trakt
            .fetchShowsCalendar(onlyMine: onlyMine)
            .then(_enrichTraktPosters);
      case SyncService.bangumi:
        return bangumi.fetchAnimeCalendar(onlyMine: onlyMine);
    }
  }

  /// Trakt 不提供图片，用条目自带的 TMDB id 从 TMDB 补封面（去重 + 缓存）。
  Future<List<CalendarEntry>> _enrichTraktPosters(
      List<CalendarEntry> entries) async {
    if (!TmdbImageService.instance.isConfigured) return entries;
    final ids = entries.map((e) => e.tmdbId).whereType<int>().toSet();
    if (ids.isEmpty) return entries;
    final posters = await TmdbImageService.instance.posters(ids);
    return entries.map((e) {
      final url = e.tmdbId == null ? null : posters[e.tmdbId];
      return url == null ? e : e.copyWith(imageUrl: url);
    }).toList();
  }

  // ---- 断开连接 ----

  Future<void> disconnect(SyncService service) async {
    await SyncSecureStore.clear(service);
    SyncSession.set(service, null);
    switch (service) {
      case SyncService.trakt:
        state = state.copyWith(clearTrakt: true);
      case SyncService.bangumi:
        state = state.copyWith(clearBangumi: true);
    }
  }
}

final syncControllerProvider =
    StateNotifierProvider<SyncController, SyncState>((ref) {
  return SyncController(ref);
});
