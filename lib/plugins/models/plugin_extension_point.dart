/// 扩展点（Extension Point）定义。
///
/// 扩展点是插件向主程序「挂载」自定义功能的位置。插件可以通过两种方式注册：
///  1. 静态：在 manifest.json 的 `extends` 字段里声明；
///  2. 动态：运行时调用 `ctx.extensions.register(type, descriptor)`。
///
/// 主程序通过 [PluginExtensionRegistry] 收集所有已注册扩展，并在对应位置渲染。
library;

/// 扩展点类型。
enum PluginExtensionType {
  /// 侧边栏 / 底部导航入口。
  sidebarItems('sidebarItems'),

  /// 媒体来源（自定义播放源 / 媒体库来源）。
  mediaSources('mediaSources'),

  /// 操作按钮（详情页 / 播放器的动作）。
  actions('actions'),

  /// 事件监听器（如 onPlayEnd、onAppStart）。
  eventListeners('eventListeners'),

  /// 设置页面。
  settingsPages('settingsPages'),

  /// 首页统计指标（显示在媒体计数旁，如流量统计）。
  homeStats('homeStats'),

  /// 播放器覆盖层（叠加在视频上的 UI）。
  playerOverlays('playerOverlays'),

  /// 右键 / 长按上下文菜单项。
  contextMenus('contextMenus');

  final String id;
  const PluginExtensionType(this.id);

  static PluginExtensionType? fromId(String id) {
    for (final t in PluginExtensionType.values) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 目标平台（用于扩展点的平台过滤）。
enum PluginPlatform { mobile, desktop, tv }

/// 各扩展点在不同平台上的支持情况。
///
/// TV 端交互模型受限（无指针/右键、布局不同），部分扩展点不支持，
/// 加载时会被忽略并记录日志（见 [PluginExtensionRegistry.register]）。
class PluginExtensionSupport {
  PluginExtensionSupport._();

  static const Map<PluginExtensionType, Set<PluginPlatform>> _support = {
    PluginExtensionType.sidebarItems: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    PluginExtensionType.mediaSources: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    PluginExtensionType.actions: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    PluginExtensionType.eventListeners: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    PluginExtensionType.settingsPages: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    PluginExtensionType.homeStats: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
      PluginPlatform.tv,
    },
    // 播放器覆盖层在 TV 上交互困难，暂不支持。
    PluginExtensionType.playerOverlays: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
    },
    // 上下文菜单依赖右键/长按，TV 端不支持。
    PluginExtensionType.contextMenus: {
      PluginPlatform.mobile,
      PluginPlatform.desktop,
    },
  };

  static bool isSupported(PluginExtensionType type, PluginPlatform platform) {
    return _support[type]?.contains(platform) ?? false;
  }
}

/// 一条已注册的扩展描述。
///
/// [data] 是插件提供的原始描述对象（JSON 可序列化的 Map），不同扩展点字段不同：
///  - sidebarItems:  { id, title, icon, route?, badge? }
///  - actions:       { id, title, icon, context: 'detail'|'player', handler }
///  - eventListeners:{ event: 'onPlayEnd'|..., handler }
///  - settingsPages: { id, title, page }  // page 由 ctx.ui 表单描述
///  - playerOverlays:{ id, align, widget }
///  - contextMenus:  { id, title, context, handler }
///  - mediaSources:  { id, title, handler }
///
/// 其中 `handler` 是插件内 JS 函数的名字，主程序通过 runtime 回调触发。
class PluginExtension {
  /// 注册该扩展的插件 id。
  final String pluginId;

  /// 扩展点类型。
  final PluginExtensionType type;

  /// 扩展在插件内的唯一 id（用于 unregister）。
  final String id;

  /// 原始描述数据。
  final Map<String, dynamic> data;

  /// 是否来自 manifest 静态声明（false = 运行时动态注册）。
  final bool fromManifest;

  PluginExtension({
    required this.pluginId,
    required this.type,
    required this.id,
    required this.data,
    this.fromManifest = false,
  });

  /// 复合键：同一插件内 type+id 唯一。
  String get key => '$pluginId::${type.id}::$id';

  String? get title => data['title'] as String?;
  String? get icon => data['icon'] as String?;

  /// 该扩展声明的 JS 处理函数名（若有）。
  String? get handler => data['handler'] as String?;
}
