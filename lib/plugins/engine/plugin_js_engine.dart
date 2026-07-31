/// 脚本引擎抽象层。
///
/// 整个插件系统只通过这个接口与 JS 引擎交互，具体实现（QuickJS / 测试桩）可替换。
/// 这样做的目的：
///  - 把对 `flutter_qjs` 的依赖收敛到唯一一个文件（[QjsPluginEngine]），
///    若三方包 API 有出入，只需改那一处；
///  - 便于单元测试时注入假引擎。
library;

/// 宿主调用分发器：JS 通过 `__lp_host(channel, method, argsJson)` 触发，
/// 由主 isolate 执行真正的能力（http/storage/player/...），返回 JSON 字符串。
typedef PluginHostDispatcher = Future<String> Function(
  String channel,
  String method,
  String argsJson,
);

/// 引擎启动失败。
class PluginEngineError implements Exception {
  final String message;
  PluginEngineError(this.message);
  @override
  String toString() => 'PluginEngineError: $message';
}

/// JS 执行超时（单次调用超过限制）。
class PluginTimeoutError implements Exception {
  final String detail;
  PluginTimeoutError(this.detail);
  @override
  String toString() => 'PluginTimeoutError: $detail';
}

abstract class PluginJsEngine {
  /// 启动引擎（创建独立运行时），注入宿主分发器并执行引导脚本与插件主脚本。
  ///
  /// [bootstrapJs] 在 [pluginJs] 之前执行，负责搭建 `ctx` 对象。
  Future<void> start({
    required String bootstrapJs,
    required String pluginJs,
    required PluginHostDispatcher dispatcher,
  });

  /// 调用 JS 全局函数 `__lp_invoke(name, argsJson)`，返回其结果的 JSON 字符串。
  ///
  /// [timeout] 到期视为插件失控，应在外层据此 [dispose] 并禁用插件。
  Future<String> invoke(String name, String argsJson, {Duration? timeout});

  /// 原始求值（主要用于内部/调试）。
  Future<dynamic> evaluate(String code, {Duration? timeout});

  /// 是否已被销毁。
  bool get isDisposed;

  /// 关闭并释放运行时。
  Future<void> dispose();
}
