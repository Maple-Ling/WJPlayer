import 'dart:async';

/// 一次播放器事件。
class PluginPlayerEvent {
  /// 事件名：onPlay / onPause / onSeek / onPlayEnd。
  final String type;

  /// 附带数据（如媒体信息），JSON 可序列化。
  final Map<String, dynamic> data;

  PluginPlayerEvent(this.type, [Map<String, dynamic>? data])
      : data = data ?? const {};
}

/// 当前活跃播放器对外暴露的控制能力（由播放器层注册，避免插件层反向依赖）。
class PluginPlayerHooks {
  Future<void> Function()? play;
  Future<void> Function()? pause;
  Future<void> Function(Duration position)? seek;
}

/// 播放器与插件系统之间的桥梁（全局单例）。
///
/// - 播放器层在初始化时 [bind] 自己的控制钩子，并在播放结束等时机 [emit] 事件；
/// - 插件运行时订阅 [events]，把事件转发给已注册 onXxx 监听的插件；
/// - 插件的 player.play/pause/seek 通过 [hooks] 控制当前播放器。
class PluginPlayerBridge {
  PluginPlayerBridge._();
  static final PluginPlayerBridge instance = PluginPlayerBridge._();

  final StreamController<PluginPlayerEvent> _controller =
      StreamController<PluginPlayerEvent>.broadcast();

  PluginPlayerHooks? _hooks;

  /// 当前正在播放的媒体快照（由播放器层在切换媒体时更新）。
  Map<String, dynamic>? currentMedia;

  Stream<PluginPlayerEvent> get events => _controller.stream;

  PluginPlayerHooks? get hooks => _hooks;

  void bind(PluginPlayerHooks hooks, {Map<String, dynamic>? media}) {
    _hooks = hooks;
    if (media != null) currentMedia = media;
  }

  void unbind(PluginPlayerHooks hooks) {
    if (identical(_hooks, hooks)) {
      _hooks = null;
      currentMedia = null;
    }
  }

  void emit(String type, [Map<String, dynamic>? data]) {
    if (_controller.isClosed) return;
    _controller.add(PluginPlayerEvent(type, data));
  }
}
