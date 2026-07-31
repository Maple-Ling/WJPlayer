/// 插件运行时的统一接口。
///
/// 三种形态各自实现：
///  - [PluginRuntime]     runtime=js    —— QuickJS 执行 main.js（桌面/安卓/TV）。
///  - `DataPluginRuntime`  runtime=data  —— 内置解释器执行声明式规则（iOS 合规）。
///  - `AddonPluginRuntime` runtime=addon —— 远程 addon 服务，按协议收发 JSON（iOS 合规）。
///
/// 管理器 [PluginManager] 只依赖本接口，不关心具体形态。
abstract class PluginRuntimeBase {
  String get pluginId;
  bool get isFaulted;

  /// 启动：注册扩展点、订阅事件、（addon）探活远程服务等。
  Future<void> load();

  /// 触发一个动态注册的 handler（handler 值为 `{__handler__: id}`）。
  Future<dynamic> invokeHandler(String handlerId, List<dynamic> args);

  /// 触发一个具名函数（manifest 静态声明的字符串 handler）。
  Future<dynamic> invokeNamed(String fnName, List<dynamic> args);

  Future<void> dispose();
}
