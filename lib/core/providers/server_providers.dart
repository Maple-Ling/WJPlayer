import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../api/emby_api.dart';
import '../network/proxy_http_client.dart';
import '../services/secure_credential_store.dart';
import '../services/server_icon_cache.dart';
import '../sources/source_credentials.dart';
import '../sources/source_kind.dart';
import '../services/watch_history/watch_history_store.dart';
import 'app_preferences.dart';
import 'watch_history_store_provider.dart';

export '../sources/source_kind.dart' show SourceKind;

enum AuthState { unauthenticated, authenticating, authenticated, error }

bool serverHasUsableAuth(ServerConfig? server) {
  final token = server?.authToken;
  return token != null && token.isNotEmpty;
}

/// 服务器取流形态（L0 自调档用，仅影响缓冲/重取流时机，不改控制流）。
/// - [unknown]：未判定，按通用档位。
/// - [cloud302]：国内 302 网盘服（签名 CDN 直链短效，暂停/seek 易过期）→ 重取流 TTL 调短。
/// - [directDisk]：硬盘直传服（长链接稳定，主要风险是跨境抖动）→ 沿用宽松档位。
enum StreamServerKind { unknown, cloud302, directDisk }

StreamServerKind streamServerKindFromName(String? name) {
  switch (name) {
    case 'cloud302':
      return StreamServerKind.cloud302;
    case 'directDisk':
      return StreamServerKind.directDisk;
    default:
      return StreamServerKind.unknown;
  }
}

class ServerConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String? iconUrl;
  final String? remark;
  final List<ServerLine> lines;
  final int activeLineIndex;
  final String? username;
  final String? authToken;
  final String? userId;
  // 登录密码（可选）。用于需要凭据重新登录的场景（如插件登录配套网站）。
  // 仅在用户添加服务器时填写后保存；通过权限 emby.credentials 暴露给插件。
  final String? password;
  // 是否信任该服务器的自签名/无效 TLS 证书（不安全）。默认 false=严格校验。
  // 仅当用户在编辑服务器页显式开启时，才把本服务器的主机加入放行白名单；
  // 不影响更新下载、WebDAV、其它主机的 TLS 校验。
  final bool allowInsecureTls;

  // L0 取流形态：从播放时的 MediaSource 被动推断（远端/直传），仅用于断流恢复调档。
  final StreamServerKind streamKind;

  // 源类型：emby（默认，现有后端）/ openlist / quark / anirss。
  // 决定选中本服务器后落到原 Emby 首页还是文件浏览页，以及用哪个 MediaSourceBackend。
  final SourceKind sourceKind;

  // 是否在服务器管理页隐藏（连点三次“服务器”标题可临时显示，隐藏后不记播放记录）。
  final bool hidden;

  ServerConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.iconUrl,
    this.remark,
    this.lines = const [],
    this.activeLineIndex = 0,
    this.username,
    this.authToken,
    this.userId,
    this.password,
    this.allowInsecureTls = false,
    this.streamKind = StreamServerKind.unknown,
    this.sourceKind = SourceKind.emby,
    this.hidden = false,
  });

  /// 是否文件浏览型源（非 Emby）。现仅飞牛。
  bool get isFileBrowse => sourceKind == SourceKind.feiniu;

  /// 当前生效的线路地址（即当前选中的线路 URL）。
  String get activeLineUrl {
    if (lines.isEmpty) return baseUrl;
    final safeIndex = activeLineIndex.clamp(0, lines.length - 1);
    return lines[safeIndex].url;
  }

  ServerConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? iconUrl,
    String? remark,
    List<ServerLine>? lines,
    int? activeLineIndex,
    String? username,
    String? authToken,
    String? userId,
    String? password,
    bool? allowInsecureTls,
    StreamServerKind? streamKind,
    SourceKind? sourceKind,
    bool? hidden,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      remark: remark ?? this.remark,
      lines: lines ?? this.lines,
      activeLineIndex: activeLineIndex ?? this.activeLineIndex,
      username: username ?? this.username,
      authToken: authToken ?? this.authToken,
      userId: userId ?? this.userId,
      password: password ?? this.password,
      allowInsecureTls: allowInsecureTls ?? this.allowInsecureTls,
      streamKind: streamKind ?? this.streamKind,
      sourceKind: sourceKind ?? this.sourceKind,
      hidden: hidden ?? this.hidden,
    );
  }
}

class ServerLine {
  final String id;
  final String name;
  final String url;
  final String? remark;

  ServerLine({
    required this.id,
    required this.name,
    required this.url,
    this.remark,
  });
}

final authStateProvider = StateProvider<AuthState>((ref) => AuthState.unauthenticated);

final serverListProvider = StateNotifierProvider<ServerListNotifier, List<ServerConfig>>((ref) {
  return ServerListNotifier(
    watchHistoryStore: ref.watch(watchHistoryStoreProvider),
  );
});

final currentServerProvider = StateNotifierProvider<CurrentServerNotifier, ServerConfig?>((ref) {
  final notifier = CurrentServerNotifier(ref.read(serverListProvider));
  ref.listen<List<ServerConfig>>(serverListProvider, (_, next) {
    notifier.syncWithAvailableServers(
      next,
      preferredServerId: notifier.selectedServerId,
    );
  });
  return notifier;
});

final apiClientProvider = Provider<ApiClientFactory>((ref) {
  final server = ref.watch(currentServerProvider);
  if (server == null) throw StateError('未连接服务器，请先添加服务器');
  return EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
});

/// 按服务器 ID 缓存的只读 ApiClient。
///
/// 聚合搜索的结果可能来自非当前服务器，解析其封面/海报、跨服务器打开前都需要
/// 对应服务器的 client。用 family 缓存复用同一实例，避免在卡片 build 路径里反复
/// `new EmbyApiClient` 泄漏 ProxyRuntime 监听（见 [EmbyApiClient.dispose]）。
/// 未登录或不存在的服务器返回 null，调用方回退到当前服务器。
final serverApiClientProvider =
    Provider.family<ApiClientFactory?, String>((ref, serverId) {
  final server =
      ref.watch(serverListProvider).where((s) => s.id == serverId).firstOrNull;
  if (server == null || (server.authToken ?? '').isEmpty) return null;
  final client = EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
  ref.onDispose(client.dispose);
  return client;
});

final currentUserProvider = FutureProvider<User?>((ref) async {
  final currentServer = ref.watch(currentServerProvider);
  if (!serverHasUsableAuth(currentServer)) return null;

  try {
    final api = ref.watch(apiClientProvider);
    return await api.user.getUser('current');
  } catch (_) {
    return null;
  }
});

class CurrentServerNotifier extends StateNotifier<ServerConfig?> {
  CurrentServerNotifier([List<ServerConfig> availableServers = const []])
      : super(_restoreCurrentServer(availableServers));

  static const _currentServerKey = 'wjplayer_current_server_id';

  String? get selectedServerId => state?.id;

  static ServerConfig? _restoreCurrentServer(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    try {
      final serverId =
          preferredServerId ?? AppPreferencesStore.instance.getString(_currentServerKey);
      if (serverId != null) {
        final saved = servers.where((server) => server.id == serverId).firstOrNull;
        if (saved != null) {
          return saved;
        }
      }
    } catch (_) {
      // Ignore restore failures and fall back below.
    }
    return servers.firstOrNull;
  }

  Future<void> loadFromSaved(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) async {
    syncWithAvailableServers(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  void syncWithAvailableServers(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    state = _restoreCurrentServer(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  Future<void> _saveCurrentServer() async {
    try {
      final prefs = AppPreferencesStore.instance;
      if (state != null) {
        await prefs.setString(_currentServerKey, state!.id);
      } else {
        await prefs.remove(_currentServerKey);
      }
    } catch (_) {
      // Ignore persistence failures and keep the in-memory state.
    }
  }

  @override
  set state(ServerConfig? value) {
    super.state = value;
    _saveCurrentServer();
  }

  void clear() {
    state = null;
  }
}

class ServerListNotifier extends StateNotifier<List<ServerConfig>> {
  /// 观看记录存储：服务器被标记隐藏时清理其历史记录（隐藏服务器不输出记录）。
  final WatchHistoryStore? watchHistoryStore;

  ServerListNotifier({this.watchHistoryStore}) : super(_loadServersSync()) {
    // 初始加载不经过 set state 覆写，这里补一次白名单同步。
    _syncInsecureTlsHosts();
    // 首启一次性把「网络 URL 图标」物化为本地文件，之后启动直接离线显示、不再重拉。
    unawaited(_materializeNetworkIcons());
  }

  /// 把仍是网络 URL 的服务器图标下载物化为本地文件并改存本地路径：此后每次启动直接
  /// `Image.file` 离线显示，不再重新获取/重试（用户手选的网络图标已在选择时物化，这里
  /// 覆盖自动探测的 touchicon 等）。拉取失败的服保持原样（继续显示默认图标），不阻塞启动。
  Future<void> _materializeNetworkIcons() async {
    for (final s in List<ServerConfig>.from(state)) {
      final url = s.iconUrl;
      if (url == null || !url.startsWith('http')) continue; // 空 / 已是本地，跳过
      final local = await ServerIconCache.persist(serverId: s.id, url: url);
      if (local == null || local == url) continue; // 拉不到就保持网络 URL 原样
      // 状态可能在下载期间被改动，按 id 核对后再更新，避免覆盖用户中途的改动。
      ServerConfig? current;
      for (final e in state) {
        if (e.id == s.id) {
          current = e;
          break;
        }
      }
      if (current != null && current.iconUrl == url) {
        updateServer(current.copyWith(iconUrl: local));
      }
    }
  }

  static const _serversKey = 'wjplayer_servers';

  // 任何服务器列表变更都重建“放行不安全 TLS”的主机白名单。
  @override
  set state(List<ServerConfig> value) {
    super.state = value;
    _syncInsecureTlsHosts();
  }

  void _syncInsecureTlsHosts() {
    final hosts = <String>{};
    for (final server in state) {
      if (!server.allowInsecureTls) continue;
      for (final url in [server.baseUrl, ...server.lines.map((l) => l.url)]) {
        final host = Uri.tryParse(url.trim())?.host;
        if (host != null && host.isNotEmpty) hosts.add(host);
      }
    }
    setInsecureTlsHosts(hosts);
  }

  static List<ServerConfig> _loadServersSync() {
    try {
      final jsonStr = AppPreferencesStore.instance.getString(_serversKey);
      if (jsonStr != null) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final servers = jsonList
            .map((entry) => _serverConfigFromJson(entry as Map<String, dynamic>))
            .toList();
        debugPrint('[ServerList] Loaded ${servers.length} servers');
        for (final server in servers) {
          debugPrint(
            '[ServerList] Loaded ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}',
          );
        }
        return servers;
      }
    } catch (e) {
      debugPrint('[ServerList] Load failed: $e');
    }
    return const [];
  }

  Future<void> _saveServers() async {
    try {
      // 持久化到 SharedPreferences 时**剥离**密码/Token（含密的明文不落 prefs）。
      final jsonList =
          state.map((s) => _serverConfigToJson(s, includeSecrets: false)).toList();
      await AppPreferencesStore.instance.setString(_serversKey, jsonEncode(jsonList));
      // 密码/Token 写入 OS 安全存储。
      for (final server in state) {
        await SecureCredentialStore.instance.write(
          server.id,
          password: server.password,
          authToken: server.authToken,
        );
      }
    } catch (e) {
      debugPrint('[ServerList] Save failed: $e');
    }
  }

  void addServer(ServerConfig server) {
    state = [...state, server];
    _saveServers();
  }

  void removeServer(String id) {
    state = state.where((server) => server.id != id).toList();
    SecureCredentialStore.instance.remove(id);
    SourceCredentialStore.instance.remove(id); // 一并清理网盘源的附加凭据
    _saveServers();
  }

  void updateServer(ServerConfig server) {
    state = state.map((entry) => entry.id == server.id ? server : entry).toList();
    _saveServers();
  }

  void replaceServers(List<ServerConfig> servers) {
    state = List<ServerConfig>.from(servers);
    _saveServers();
  }

  void reorderServers(int oldIndex, int newIndex) {
    final servers = List<ServerConfig>.from(state);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final server = servers.removeAt(oldIndex);
    servers.insert(newIndex, server);
    state = servers;
    _saveServers();
  }

  /// 直接用重排后的完整列表覆盖顺序（双排长按拖动排序用，长度必须一致）。
  void reorderTo(List<ServerConfig> ordered) {
    if (ordered.length != state.length) return;
    state = List<ServerConfig>.from(ordered);
    _saveServers();
  }

  void setActiveLine(String serverId, int lineIndex) {
    state = state.map((server) {
      if (server.id == serverId) {
        final safeIndex = server.lines.isEmpty
            ? 0
            : lineIndex.clamp(0, server.lines.length - 1);
        return server.copyWith(activeLineIndex: safeIndex);
      }
      return server;
    }).toList();
    _saveServers();
  }

  /// L0：回填服务器取流形态（首次播放时按 MediaSource 推断）。无变化则跳过，避免无谓持久化。
  void setStreamKind(String serverId, StreamServerKind kind) {
    var changed = false;
    final next = state.map((server) {
      if (server.id == serverId && server.streamKind != kind) {
        changed = true;
        return server.copyWith(streamKind: kind);
      }
      return server;
    }).toList();
    if (!changed) return;
    state = next;
    _saveServers();
  }

  /// 隐藏 / 显示服务器（管理页三点菜单；隐藏后不记播放记录）。
  /// 仅「非隐藏 → 隐藏」时清理该服务器已有观看记录（隐藏服务器不输出记录，
  /// 旧记录一并删除）；重复点击/初始即隐藏不触发，避免误删。
  void setHidden(String serverId, bool hidden) {
    final wasHidden =
        state.any((s) => s.id == serverId && s.hidden == true);
    state = state.map((server) {
      if (server.id == serverId) return server.copyWith(hidden: hidden);
      return server;
    }).toList();
    _saveServers();
    if (hidden && !wasHidden) {
      unawaited(watchHistoryStore?.deleteByScopePrefix(serverId));
    }
  }
}

/// 序列化服务器配置。[includeSecrets] 为 false 时**不写入**密码/Token
/// （用于 SharedPreferences 持久化，密文改存 OS 安全存储）；备份导出需带凭据
/// 时传 true（备份会另行用口令加密整包，见 H12）。
Map<String, dynamic> _serverConfigToJson(ServerConfig server,
    {bool includeSecrets = true}) {
  return {
    'id': server.id,
    'name': server.name,
    'baseUrl': server.baseUrl,
    'iconUrl': server.iconUrl,
    'remark': server.remark,
    'lines': server.lines
        .map((line) => {
              'id': line.id,
              'name': line.name,
              'url': line.url,
              'remark': line.remark,
            })
        .toList(),
    'activeLineIndex': server.activeLineIndex,
    'username': server.username,
    if (includeSecrets) 'authToken': server.authToken,
    'userId': server.userId,
    if (includeSecrets) 'password': server.password,
    'allowInsecureTls': server.allowInsecureTls,
    'streamKind': server.streamKind.name,
    'sourceKind': server.sourceKind.name,
    'hidden': server.hidden,
  };
}

ServerConfig _serverConfigFromJson(Map<String, dynamic> json) {
  final lines = (json['lines'] as List<dynamic>?)
          ?.map(
            (line) => ServerLine(
              id: line['id'] as String,
              name: line['name'] as String,
              url: line['url'] as String,
              remark: line['remark'] as String?,
            ),
          )
          .toList() ??
      const <ServerLine>[];
  final activeLineIndex = json['activeLineIndex'] as int? ?? 0;
  final id = json['id'] as String;
  final sourceKind = sourceKindFromName(json['sourceKind'] as String?);
  final normalizedLines = lines.isEmpty && sourceKind == SourceKind.feiniu
      ? [ServerLine(id: 'default', name: '默认线路', url: json['baseUrl'] as String)]
      : lines;
  // （SharedPreferences 持久化路径已剥离密码/Token）。
  final secret = SecureCredentialStore.instance.read(id);

  return ServerConfig(
    id: id,
    name: json['name'] as String,
    baseUrl: json['baseUrl'] as String,
    iconUrl: json['iconUrl'] as String?,
    remark: json['remark'] as String?,
    lines: normalizedLines,
    activeLineIndex: normalizedLines.isEmpty
        ? 0
        : activeLineIndex.clamp(0, normalizedLines.length - 1),
    username: _emptyToNull(json['username'] as String?),
    authToken: _emptyToNull(json['authToken'] as String?) ?? secret?.authToken,
    userId: _emptyToNull(json['userId'] as String?),
    password: _emptyToNull(json['password'] as String?) ?? secret?.password,
    // 迁移：旧版本服务器无此字段，过去对所有主机放行坏证书。为不破坏现有
    // （含自签名 Emby）用户的连接，缺字段时默认 true 保留原放行行为；放行范围
    // 已收敛到本服务器自身主机。新加服务器走构造默认 false（严格校验）。
    allowInsecureTls: json['allowInsecureTls'] as bool? ?? true,
    // 迁移：旧数据无此字段 → unknown，首次播放时按 MediaSource 推断回填。
    streamKind: streamServerKindFromName(json['streamKind'] as String?),
    // 迁移：旧数据无此字段 → emby（保持原 Emby 行为）。
    sourceKind: sourceKindFromName(json['sourceKind'] as String?),
    hidden: json['hidden'] as bool? ?? false,
  );
}

Map<String, dynamic> serverConfigToJson(ServerConfig server) => _serverConfigToJson(server);

ServerConfig serverConfigFromJson(Map<String, dynamic> json) => _serverConfigFromJson(json);

String? _emptyToNull(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}
