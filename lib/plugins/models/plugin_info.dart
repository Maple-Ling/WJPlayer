import 'plugin_manifest.dart';

/// 插件的运行时状态。
enum PluginStatus {
  /// 已安装，未启用。
  disabled,

  /// 正在加载（执行 main.js）。
  loading,

  /// 已启用并正常运行。
  enabled,

  /// 加载或运行出错（含超时被禁用）。
  error,
}

/// 一个已安装插件的完整信息（清单 + 磁盘路径 + 运行时状态）。
class PluginInfo {
  final PluginManifest manifest;

  /// 插件解压后所在目录（绝对路径）。
  final String directory;

  /// 入口 JS 文件的绝对路径。
  final String entryPath;

  PluginStatus status;

  /// 出错时的原因（展示给用户）。
  String? error;

  /// 是否曾因超时/崩溃被强制禁用（需用户手动恢复）。
  bool faulted;

  PluginInfo({
    required this.manifest,
    required this.directory,
    required this.entryPath,
    this.status = PluginStatus.disabled,
    this.error,
    this.faulted = false,
  });

  String get id => manifest.id;
  String get name => manifest.name;
  String get version => manifest.version;

  bool get isEnabled => status == PluginStatus.enabled;
}
