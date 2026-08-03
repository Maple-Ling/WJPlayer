/// 插件权限模型。
///
/// 权限采用「声明制」：插件在 manifest.json 的 `permissions` 数组中声明所需能力，
/// 用户在启用插件前必须明确同意。运行时每次调用 ctx.* API 都会做权限检查，
/// 未授权的调用会抛出 [PluginPermissionError]，由插件侧捕获为 JS 异常。
library;

/// 单个权限定义。
class PluginPermission {
  /// 权限唯一标识，写在 manifest 的 permissions 数组里。
  final String id;

  /// 面向用户的中文名称。
  final String title;

  /// 面向用户的说明（用于授权弹窗）。
  final String description;

  /// 是否为「危险」权限（涉及网络/隐私），UI 上需要强调。
  final bool dangerous;

  const PluginPermission({
    required this.id,
    required this.title,
    required this.description,
    this.dangerous = false,
  });
}

/// 所有内置可申请的权限。
class PluginPermissions {
  PluginPermissions._();

  static const playerRead = PluginPermission(
    id: 'player.read',
    title: '读取播放状态',
    description: '获取当前播放的媒体信息、播放进度，并监听播放事件（如播放结束）。',
  );

  static const playerControl = PluginPermission(
    id: 'player.control',
    title: '控制播放器',
    description: '可以播放、暂停、跳转当前视频。',
    dangerous: true,
  );

  static const http = PluginPermission(
    id: 'http',
    title: '网络访问',
    description: '通过 HTTPS 访问外部网络（受域名白名单限制）。',
    dangerous: true,
  );

  static const storage = PluginPermission(
    id: 'storage',
    title: '本地存储',
    description: '在本地保存插件自己的数据（每个插件独立，上限 5MB）。',
  );

  static const ui = PluginPermission(
    id: 'ui',
    title: '界面交互',
    description: '弹出提示、对话框，或打开插件页面。',
  );

  static const embyRead = PluginPermission(
    id: 'emby.read',
    title: '读取 Emby 信息',
    description: '读取当前登录用户和服务器地址。',
  );

  static const embyApi = PluginPermission(
    id: 'emby.api',
    title: '调用 Emby 接口',
    description: '以当前登录身份向 Emby 服务器发起任意 API 请求。',
    dangerous: true,
  );

  static const embyCredentials = PluginPermission(
    id: 'emby.credentials',
    title: '读取登录账号密码',
    description: '读取你添加服务器时填写的用户名与密码（用于代你登录配套网站）。',
    dangerous: true,
  );

  static const extensions = PluginPermission(
    id: 'extensions',
    title: '扩展界面',
    description: '向应用注册侧边栏入口、操作按钮、设置页等扩展点。',
  );

  /// `log` 权限默认始终授予，无需声明，这里仅用于展示。
  static const log = PluginPermission(
    id: 'log',
    title: '写日志',
    description: '输出调试日志（始终允许）。',
  );

  static const List<PluginPermission> all = [
    playerRead,
    playerControl,
    http,
    storage,
    ui,
    embyRead,
    embyApi,
    embyCredentials,
    extensions,
    log,
  ];

  static final Map<String, PluginPermission> _byId = {
    for (final p in all) p.id: p,
  };

  /// 始终授予、无需声明的权限集合。
  static const Set<String> implicitlyGranted = {'log'};

  static PluginPermission? byId(String id) => _byId[id];

  /// 该权限是否为应用已知权限（用于 manifest 校验）。
  static bool isKnown(String id) => _byId.containsKey(id);
}

/// 一组已授予的权限。
class PluginGrantedPermissions {
  final Set<String> _ids;

  PluginGrantedPermissions(Iterable<String> ids)
      : _ids = {...ids, ...PluginPermissions.implicitlyGranted};

  bool has(String id) => _ids.contains(id);

  Set<String> get ids => Set.unmodifiable(_ids);

  /// 是否覆盖了 [required] 中的所有权限。
  bool covers(Iterable<String> required) => required.every(_ids.contains);
}

/// 权限被拒绝时抛出，会被转换为插件内的 JS 异常。
class PluginPermissionError implements Exception {
  final String permissionId;
  final String pluginId;

  PluginPermissionError(this.pluginId, this.permissionId);

  @override
  String toString() =>
      'PluginPermissionError: 插件 $pluginId 缺少权限「$permissionId」';
}
