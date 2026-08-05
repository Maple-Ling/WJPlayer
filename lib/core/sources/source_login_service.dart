import 'package:uuid/uuid.dart';

import '../providers/server_providers.dart';
import 'feiniu_backend.dart';
import 'media_source_backend.dart';
import 'source_http.dart';

/// 账密登录并构造（尚未持久化的）网盘源 [ServerConfig]。
///
/// UI 拿到返回值后自行 `serverListProvider.addServer(...)` 落库、设为当前服务器，
/// 保持 core 层不依赖 Riverpod。登录失败抛 [SourceException]。
class SourceLoginService {
  static const _uuid = Uuid();

  /// 飞牛影视账密登录。
  static Future<ServerConfig> loginFeiniu({
    required String name,
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    final token = await FeiniuBackend.login(base, username, password);
    final host = Uri.tryParse(base)?.host ?? base;
    return ServerConfig(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? host : name.trim(),
      baseUrl: base,
      username: username.trim(),
      password: password,
      authToken: token,
      lines: [ServerLine(id: 'default', name: '默认线路', url: base)],
      activeLineIndex: 0,
      sourceKind: SourceKind.feiniu,
    );
  }
}
