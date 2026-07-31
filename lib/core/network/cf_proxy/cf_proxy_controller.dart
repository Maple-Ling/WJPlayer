import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_preferences.dart';
import '../../providers/server_providers.dart';
import '../../services/app_logger.dart';
import 'cf_proxy_runtime.dart';
import 'cf_reverse_proxy.dart';
import 'cf_speed_tester.dart';

/// 某台服务器的 CF 优选反代状态（可持久化的那部分）。
class CfServerState {
  final String serverId;
  String? pinnedIp;
  bool enabled; // 反代是否处于开启状态
  bool scheduleEnabled; // 是否定时测速
  int scheduleMinutes; // 定时间隔（分钟）
  String? testUrl; // 自定义测速文件（null=用全局/默认）
  CfTestResult? lastResult;
  int? lastTestedAtMs;

  CfServerState({
    required this.serverId,
    this.pinnedIp,
    this.enabled = false,
    this.scheduleEnabled = false,
    this.scheduleMinutes = 30,
    this.testUrl,
    this.lastResult,
    this.lastTestedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'pinnedIp': pinnedIp,
        'enabled': enabled,
        'scheduleEnabled': scheduleEnabled,
        'scheduleMinutes': scheduleMinutes,
        'testUrl': testUrl,
        'lastResult': lastResult?.toJson(),
        'lastTestedAtMs': lastTestedAtMs,
      };

  static CfServerState fromJson(Map<String, dynamic> j) => CfServerState(
        serverId: j['serverId'] as String,
        pinnedIp: j['pinnedIp'] as String?,
        enabled: j['enabled'] as bool? ?? false,
        scheduleEnabled: j['scheduleEnabled'] as bool? ?? false,
        scheduleMinutes: (j['scheduleMinutes'] as num?)?.toInt() ?? 30,
        testUrl: j['testUrl'] as String?,
        lastResult: CfTestResult.fromJson(
            (j['lastResult'] as Map?)?.cast<String, dynamic>()),
        lastTestedAtMs: (j['lastTestedAtMs'] as num?)?.toInt(),
      );
}

/// CF 优选反代总控（全局单例）。负责：测速 → 启停本地反代 → 持久化 →
/// 定时复测 → 启动时按需恢复。UI（面板/插件）只调用它，不直接碰底层。
class CfProxyController extends ChangeNotifier {
  CfProxyController._();
  static final CfProxyController instance = CfProxyController._();

  static final AppLogger _log = AppLogger();
  static const _prefsKey = 'cf_proxy_states_v1';
  static const _globalTestUrlKey = 'cf_proxy_global_test_url';
  static const _ipModeKey = 'cf_proxy_ip_mode';

  ProviderContainer? _container;
  bool _loaded = false;

  final Map<String, CfServerState> _states = {};
  final Map<String, CfReverseProxy> _proxies = {};
  final Map<String, Timer> _timers = {};
  final Set<String> _running = {}; // 正在测速的 serverId，防重入

  String _globalTestUrl = kDefaultCfTestUrl;
  String get globalTestUrl => _globalTestUrl;

  CfIpMode _ipMode = CfIpMode.auto;
  CfIpMode get ipMode => _ipMode;

  /// 注入 Riverpod 容器并加载持久化状态。可重复调用（幂等）。
  void ensureInit(ProviderContainer container) {
    _container = container;
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  CfServerState? stateFor(String serverId) => _states[serverId];
  bool isActive(String serverId) => CfProxyRuntime.instance.isActive(serverId);
  bool isRunning(String serverId) => _running.contains(serverId);

  ServerConfig? _server(String serverId) {
    final c = _container;
    if (c == null) return null;
    for (final s in c.read(serverListProvider)) {
      if (s.id == serverId) return s;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 测速 + 应用
  // ---------------------------------------------------------------------------

  /// 对某台服务器测速并把最优 IP 应用为反代。返回最优结果（失败为 null）。
  Future<CfTestResult?> speedTestAndApply(
    String serverId, {
    void Function(CfTestProgress)? onProgress,
    CfCancelToken? cancel,
    int? sampleCount,
    bool silent = false,
  }) async {
    if (_running.contains(serverId)) return null;
    final server = _server(serverId);
    if (server == null) {
      throw StateError('找不到服务器: $serverId');
    }
    _running.add(serverId);
    notifyListeners();
    try {
      final state = _states.putIfAbsent(
          serverId, () => CfServerState(serverId: serverId));
      final testUrl = (state.testUrl?.trim().isNotEmpty == true)
          ? state.testUrl!.trim()
          : _globalTestUrl;
      // 用服务器自身域名做 HTTP 校验（/cdn-cgi/trace 由 CF 边缘应答，不回源）。
      final validateHost = Uri.tryParse(server.directLineUrl)?.host ?? '';
      final options = CfSpeedTestOptions(testUrl: testUrl).copyWith(
        sampleCount: sampleCount,
        ipMode: _ipMode,
        validateHost: validateHost,
      );

      final results = await CfSpeedTester()
          .run(options: options, onProgress: onProgress, cancel: cancel);
      if (cancel?.canceled == true) return null;
      if (results.isEmpty) return null;

      final best = results.first;
      state.lastResult = best;
      state.lastTestedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _applyIp(server, best.ip);
      await _persist();
      notifyListeners();
      if (!silent) {
        _log.i('CfProxy',
            '[${server.name}] 优选完成 -> ${best.ip} ${best.latencyMs}ms ${best.downloadKBps != null ? '${(best.downloadKBps! / 1024).toStringAsFixed(2)}MB/s' : ''}');
      }
      return best;
    } finally {
      _running.remove(serverId);
      notifyListeners();
    }
  }

  /// 把某 IP 应用为该服务器的反代上游：已开则热切换 IP，未开则启动反代并改写路由。
  Future<void> _applyIp(ServerConfig server, String ip) async {
    final serverId = server.id;
    final existing = _proxies[serverId];
    final state =
        _states.putIfAbsent(serverId, () => CfServerState(serverId: serverId));
    state.pinnedIp = ip;
    state.enabled = true;

    if (existing != null) {
      // 端口与本地地址不变，仅热切换上游 IP，对正在进行的会话无感。
      existing.updateIp(ip);
      return;
    }

    final upstream = Uri.parse(server.directLineUrl);
    final proxy = CfReverseProxy(
      upstreamScheme: upstream.scheme.isEmpty ? 'https' : upstream.scheme,
      upstreamHost: upstream.host,
      upstreamPort: upstream.hasPort
          ? upstream.port
          : (upstream.scheme == 'http' ? 80 : 443),
      ip: ip,
      allowInsecureTls: server.allowInsecureTls,
    );
    await proxy.start();
    _proxies[serverId] = proxy;

    final localUrl = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: proxy.port,
      path: upstream.path,
    ).toString();
    CfProxyRuntime.instance.bind(serverId, localUrl);
    _forceRebuild(serverId);
  }

  /// 关闭某服务器的反代，恢复直连原线路。
  Future<void> disable(String serverId) async {
    CfProxyRuntime.instance.unbind(serverId);
    final proxy = _proxies.remove(serverId);
    await proxy?.stop();
    final state = _states[serverId];
    if (state != null) {
      state.enabled = false;
    }
    _stopTimer(serverId);
    if (state != null) state.scheduleEnabled = false;
    await _persist();
    _forceRebuild(serverId);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 定时测速
  // ---------------------------------------------------------------------------

  Future<void> setSchedule(
      String serverId, bool enabled, int minutes) async {
    final state =
        _states.putIfAbsent(serverId, () => CfServerState(serverId: serverId));
    state.scheduleEnabled = enabled;
    state.scheduleMinutes = minutes.clamp(5, 1440);
    _stopTimer(serverId);
    if (enabled) {
      _startTimer(serverId, state.scheduleMinutes);
    }
    await _persist();
    notifyListeners();
  }

  void _startTimer(String serverId, int minutes) {
    _timers[serverId] = Timer.periodic(Duration(minutes: minutes), (_) async {
      try {
        await speedTestAndApply(serverId, silent: true);
      } catch (e) {
        _log.w('CfProxy', '定时测速失败($serverId): $e');
      }
    });
  }

  void _stopTimer(String serverId) {
    _timers.remove(serverId)?.cancel();
  }

  // ---------------------------------------------------------------------------
  // 配置
  // ---------------------------------------------------------------------------

  Future<void> setServerTestUrl(String serverId, String? url) async {
    final state =
        _states.putIfAbsent(serverId, () => CfServerState(serverId: serverId));
    state.testUrl = (url?.trim().isEmpty ?? true) ? null : url!.trim();
    await _persist();
    notifyListeners();
  }

  Future<void> setIpMode(CfIpMode mode) async {
    _ipMode = mode;
    try {
      await AppPreferencesStore.instance.setString(_ipModeKey, mode.name);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setGlobalTestUrl(String url) async {
    final v = url.trim();
    _globalTestUrl = v.isEmpty ? kDefaultCfTestUrl : v;
    try {
      await AppPreferencesStore.instance
          .setString(_globalTestUrlKey, _globalTestUrl);
    } catch (_) {}
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 生命周期：恢复 / 拆除
  // ---------------------------------------------------------------------------

  /// 启动（或插件启用）时按持久化状态恢复反代与定时器，不重新测速（沿用上次 IP）。
  Future<void> restoreAll() async {
    for (final state in _states.values.toList()) {
      final server = _server(state.serverId);
      if (server == null) continue;
      if (state.enabled && (state.pinnedIp?.isNotEmpty ?? false)) {
        try {
          await _applyIp(server, state.pinnedIp!);
        } catch (e) {
          _log.w('CfProxy', '恢复反代失败(${state.serverId}): $e');
        }
      }
      if (state.scheduleEnabled) {
        _startTimer(state.serverId, state.scheduleMinutes);
      }
    }
    notifyListeners();
  }

  /// 拆除所有反代与定时器（插件禁用/退出时调用），但保留持久化配置以便下次恢复。
  Future<void> teardownAll() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final entry in _proxies.entries.toList()) {
      CfProxyRuntime.instance.unbind(entry.key);
      await entry.value.stop();
      _forceRebuild(entry.key);
    }
    _proxies.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 改写路由后强制相关 Provider 重建，让新的 activeLineUrl 立刻生效。
  void _forceRebuild(String serverId) {
    final c = _container;
    if (c == null) return;
    final server = _server(serverId);
    if (server != null) {
      // 推一个全新的 ServerConfig 实例，触发 currentServer/apiClient 重建链。
      c.read(serverListProvider.notifier).updateServer(server.copyWith());
    }
    try {
      c.invalidate(serverApiClientProvider(serverId));
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final list = _states.values.map((s) => s.toJson()).toList();
      await AppPreferencesStore.instance
          .setString(_prefsKey, jsonEncode(list));
    } catch (e) {
      _log.w('CfProxy', '持久化失败: $e');
    }
  }

  void _load() {
    try {
      _globalTestUrl =
          AppPreferencesStore.instance.getString(_globalTestUrlKey) ??
              kDefaultCfTestUrl;
      _ipMode =
          cfIpModeFromName(AppPreferencesStore.instance.getString(_ipModeKey));
      final raw = AppPreferencesStore.instance.getString(_prefsKey);
      if (raw != null) {
        final list = (jsonDecode(raw) as List).cast<dynamic>();
        for (final e in list) {
          final s = CfServerState.fromJson((e as Map).cast<String, dynamic>());
          _states[s.serverId] = s;
        }
      }
    } catch (e) {
      _log.w('CfProxy', '加载持久化状态失败: $e');
    }
  }
}
