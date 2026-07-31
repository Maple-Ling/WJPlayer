/// CF 优选反代的「路由改写」运行时（全局单例）。
///
/// 这是整套 CF 优选的**唯一改写点**：当某台服务器开启了优选反代后，
/// 这里登记 `serverId -> 本地反代地址(http://127.0.0.1:port/...)`。
/// [ServerConfig.activeLineUrl] 取值时会先查这里，命中则返回本地反代地址，
/// 于是 Dio API 客户端与 mpv 取流 URL 都自动改走本地反代 → 上游优选 CF IP，
/// 与播放器实现无关，三端通用。
///
/// 故意做得极薄、无任何重依赖，方便被 `server_providers.dart` 直接 import
/// 而不引入循环依赖。真正的启停/测速逻辑在 [CfProxyController]。
class CfProxyRuntime {
  CfProxyRuntime._();
  static final CfProxyRuntime instance = CfProxyRuntime._();

  /// serverId -> 本地反代基址（含原 base 的路径前缀）。
  final Map<String, String> _localUrls = {};

  /// 命中则返回本地反代地址，否则 null（走原始线路）。
  String? localUrlFor(String serverId) => _localUrls[serverId];

  void bind(String serverId, String localUrl) {
    _localUrls[serverId] = localUrl;
  }

  void unbind(String serverId) {
    _localUrls.remove(serverId);
  }

  bool isActive(String serverId) => _localUrls.containsKey(serverId);

  bool get hasAny => _localUrls.isNotEmpty;
}
