import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'anime4k_shaders.dart';
import 'app_logger.dart';
import 'player_adapter.dart';

/// 原生渲染时，设置面板贴屏幕右侧，会盖在视频洞上。若不排除，面板会被挖穿变透明。
/// [showPlayerSettingsPanel] 通过它广播「面板占屏幕宽度的比例」（0 = 关闭，如 0.33/0.5），
/// [WindowsNativeMpvAdapter] 监听后把右侧该比例宽度从洞里排除（保持面板不透明可见）。
/// 非 Windows/非原生渲染时无副作用。
final ValueNotifier<double> nativeRenderPanelFraction = ValueNotifier<double>(0);

/// 原生渲染时，鼠标在视频洞上移动/点击，Flutter 收不到（洞不属于 Flutter 窗口）。
/// 适配器轮询真实光标，检测到在视频区活动就自增此 tick；播放页监听后唤出控制栏。
final ValueNotifier<int> nativeRenderPointerTick = ValueNotifier<int>(0);

/// 自研 Lua 控制栏发来的命令（写在 mpv user-data/wjplayer/cmd，适配器轮询读取转发）。
/// 取值：back / fullscreen / next / prev / subtitle / audio / superres / episodes / aspect / more。
/// 播放页订阅后调用对应的现有方法（复用 Flutter 面板/导航逻辑）。
final StreamController<String> _nativeCmdController =
    StreamController<String>.broadcast();
Stream<String> get nativeRenderCmdStream => _nativeCmdController.stream;

/// M1 · Windows 原生 mpv 渲染适配器。
///
/// 通过 `com.mapleling.wjplayer/native_render` 通道驱动 runner 里的 [NativeMpvRender]（C++）：
/// mpv 用 `--wid` 嵌进一个子 HWND，`vo=gpu-next`+`gpu-context=d3d11` 自建 swapchain
/// **直接上屏**，绕开 media_kit 的离屏纹理 + ANGLE 逐帧翻译——治「5060 都卡」的根。
///
/// 里程碑边界（M1，仅验证真机流畅度）：
///   - 控制用 mpv 自带 OSC（osc=yes + 键鼠绑定），**暂无 Flutter 控件叠加**；
///   - 位置/时长/暂停靠 Dart 轮询 getProperty，**暂无事件通道**（M2 再补）；
///   - 字幕轨/音轨/续播上报等平价功能留到 M3。
/// 播放页控件目前被原生子窗口盖住是**已知现象**，不是 bug——先测原生直出流不流畅。
class WindowsNativeMpvAdapter extends PlayerAdapter {
  static final _logger = AppLogger();
  static const _channel = MethodChannel('com.mapleling.wjplayer/native_render');
  // 120ms：兼顾位置/时长刷新与「移动鼠标唤出控制栏」的响应（洞上鼠标只能靠轮询）。
  static const _pollInterval = Duration(milliseconds: 120);

  // v2：控制栏改由 mpv 自带 OSC/uosc 在自己的窗口里画，不再用 Flutter 控件浮在洞上，
  // 故不再从洞里切上下控制条（洞=整块视频，mpv OSC 直接画在其中）。设置面板仍需排除。
  // 若日后修好 Flutter-over-hole，把此改回 false 即恢复 Flutter 控制栏 cutout。
  static const bool _useMpvOsc = true;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;

  Timer? _pollTimer;
  PlayerStateCallbacks? _callbacks;

  // ── 挖洞几何 ───────────────────────────────────────────────────────────
  // 视频物理矩形 + 控制栏上/下条物理高度（由占位组件每帧上报）；控件可见状态
  // 由播放页推送。合并算出「洞 = 视频矩形 − 可见控件」下发 C++。
  Rect? _videoRect;
  int _topBandPx = 0;
  int _botBandPx = 0;
  bool _controlsVisible = true;
  double _panelFraction = 0;
  List<int>? _lastHolePayload;
  VoidCallback? _panelListener;

  WindowsNativeMpvAdapter() {
    _panelListener =
        () => setChrome(panelFraction: nativeRenderPanelFraction.value);
    nativeRenderPanelFraction.addListener(_panelListener!);
  }

  @override
  bool get isInitialized => _isInitialized;
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isBuffering => _isBuffering;
  @override
  bool get isCompleted => _isCompleted;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  double get speed => _speed;
  @override
  double get volume => _volume;
  @override
  double get progress {
    final d = _duration.inMilliseconds;
    if (d <= 0) return 0.0;
    return _position.inMilliseconds / d;
  }

  @override
  bool get hasError => _errorMessage != null;
  @override
  String? get errorMessage => _errorMessage;
  @override
  int? get textureId => null;
  @override
  List<Map<String, dynamic>> getTracksInfo() => const [];
  @override
  void setCallbacks(PlayerStateCallbacks callbacks) => _callbacks = callbacks;

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    bool hardwareDecoding = true,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,
    bool useGpuNext = false,
    Map<String, String>? httpHeaders,
    String? userAgentOverride,
    String? superResolutionLevel,
    bool zeroCopyHwdec = false,
  }) async {
    try {
      final shaders =
          await resolveAnime4KShaderPaths(superResolutionLevel, native: true);
      await _channel.invokeMethod('init', {
        'url': videoUrl,
        'startMs': startPosition?.inMilliseconds ?? 0,
        'shaders': shaders,
        'headers': httpHeaders ?? const <String, String>{},
        'userAgent': userAgentOverride ?? '',
        // 数字键超分（M1 控制手段：Flutter 菜单被原生窗口盖住，用 mpv 绑键 + OSD 直达）。
        'superres': await _buildSuperresBindings(),
      });
      _isInitialized = true;
      _isPlaying = true;
      _startPolling();
      _logger.i('WinNativeMpv',
          '原生渲染初始化完成: shaders=${shaders.length}, level=$superResolutionLevel');
    } catch (e, st) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('WinNativeMpv', '原生渲染初始化失败', e, st);
      _callbacks?.onError?.call();
    }
  }

  // 数字键 → 超分预设绑定（0=关，1-6=六档去噪梯子，与桌面菜单标签一致）。
  // 键名沿用 anime4k_shaders.dart 的单一事实源，别在这里另立映射。
  static const List<(String, String, String)> _superresKeymap = [
    ('0', '关', 'off'),
    ('1', 'Mode A', 'modeA'),
    ('2', 'Mode B', 'modeB'),
    ('3', 'Mode C', 'modeC'),
    ('4', 'Mode A+A', 'modeAA'),
    ('5', 'Mode B+B', 'modeBB'),
    ('6', 'Mode C+A', 'modeAC'),
  ];

  Future<List<Map<String, Object>>> _buildSuperresBindings() async {
    final out = <Map<String, Object>>[];
    for (final (key, label, level) in _superresKeymap) {
      out.add({
        'key': key,
        'label': label,
        'paths': await resolveAnime4KShaderPaths(level, native: true),
      });
    }
    return out;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (!_isInitialized) return;
    // cmd 桥独立轮询：绝不能被下面属性读取的异常连带跳过（那会让控制栏按钮全失灵）。
    try {
      await _pollCmd();
    } catch (_) {}
    try {
      final pos = _parseSeconds(await _getProp('time-pos'));
      final dur = _parseSeconds(await _getProp('duration'));
      final paused = (await _getProp('pause')) == 'yes';
      final eof = (await _getProp('eof-reached')) == 'yes';
      final cache = (await _getProp('paused-for-cache')) == 'yes';

      if (dur != null && dur != _duration) {
        _duration = dur;
        _callbacks?.onDurationChanged?.call();
      }
      if (pos != null && pos != _position) {
        _position = pos;
        _callbacks?.onPositionChanged?.call();
      }
      final nowPlaying = !paused;
      if (nowPlaying != _isPlaying) {
        _isPlaying = nowPlaying;
        _callbacks?.onPlayingStateChanged?.call();
      }
      if (cache != _isBuffering) {
        _isBuffering = cache;
        _callbacks?.onBufferingStateChanged?.call();
      }
      if (eof && !_isCompleted) {
        _isCompleted = true;
        _callbacks?.onCompleted?.call();
      }
      await _pollPointer();
    } catch (_) {
      // 轮询失败不致命，下一拍再试。
    }
  }

  // 读取 Lua 控制栏投递的命令（user-data/wjplayer/cmd），转发给播放页后清空信箱。
  Future<void> _pollCmd() async {
    final raw = await _getProp('user-data/wjplayer/cmd');
    if (raw.isEmpty) return;
    // get_property_string 读 user-data 字符串节点返回 JSON 带引号（"fullscreen"），
    // 剥掉引号再派发，否则匹配不上 switch 的 case。
    final cmd = raw.replaceAll('"', '').trim();
    if (cmd.isEmpty) return;
    _nativeCmdController.add(cmd);
    await _channel.invokeMethod('setProperty',
        {'name': 'user-data/wjplayer/cmd', 'value': ''});
  }

  String? _lastTitle;

  /// 把标题推给 uosc（走 force-media-title，uosc 顶栏读 media-title 显示）。仅变化时下发。
  Future<void> pushUiState({String? title, bool? hasSeries, bool? superres}) async {
    if (title != null && title.isNotEmpty && title != _lastTitle) {
      _lastTitle = title;
      try {
        await _channel.invokeMethod(
            'setProperty', {'name': 'force-media-title', 'value': title});
      } catch (_) {}
    }
  }

  double? _lastPtrX;
  double? _lastPtrY;

  // 轮询真实光标：在视频洞上移动/点击时唤出控制栏（Flutter 在洞上收不到鼠标）。
  Future<void> _pollPointer() async {
    final ptr = await _channel.invokeMethod<Map<Object?, Object?>>('getPointer');
    if (ptr == null) return;
    final x = (ptr['x'] as num?)?.toDouble();
    final y = (ptr['y'] as num?)?.toDouble();
    final down = ptr['primaryDown'] == true;
    if (x == null || y == null) return;
    final moved = _lastPtrX != null && (x != _lastPtrX || y != _lastPtrY);
    _lastPtrX = x;
    _lastPtrY = y;
    if (moved || down) {
      nativeRenderPointerTick.value++;
    }
  }

  Future<String> _getProp(String name) async {
    final v = await _channel.invokeMethod<String>('getProperty', {'name': name});
    return v ?? '';
  }

  Duration? _parseSeconds(String raw) {
    if (raw.isEmpty) return null;
    final s = double.tryParse(raw);
    if (s == null) return null;
    return Duration(milliseconds: (s * 1000).round());
  }

  @override
  Widget buildVideo() => _NativeRenderSurface(adapter: this);

  /// 占位组件每帧上报：视频区物理矩形 + 控制栏上/下条物理高度。
  void reportGeometry(Rect rect, int topBandPx, int botBandPx) {
    _videoRect = rect;
    _topBandPx = topBandPx;
    _botBandPx = botBandPx;
    _pushHole();
  }

  /// 播放页推送当前控件可见状态，据此决定洞要避开哪些区域。
  /// [controls] 控制栏（上/下条）是否可见；[panelFraction] 右侧设置面板占屏宽比例
  /// （0 = 关闭）。
  void setChrome({bool? controls, double? panelFraction}) {
    if (controls != null) _controlsVisible = controls;
    if (panelFraction != null) _panelFraction = panelFraction;
    _pushHole();
  }

  // 合并视频矩形 + 可见控件 cutout，下发 C++ 更新洞。payload 未变则不打通道。
  void _pushHole() {
    final r = _videoRect;
    if (r == null) return;
    final left = r.left.round();
    final top = r.top.round();
    final width = r.width.round();
    final height = r.height.round();
    if (width <= 0 || height <= 0) return;

    final cutouts = <List<int>>[];
    if (_controlsVisible && !_useMpvOsc) {
      if (_topBandPx > 0) cutouts.add([left, top, width, _topBandPx]);
      if (_botBandPx > 0) {
        cutouts.add([left, top + height - _botBandPx, width, _botBandPx]);
      }
    }
    if (_panelFraction > 0) {
      final panelW = (width * _panelFraction).clamp(0, width).round();
      if (panelW > 0) cutouts.add([left + width - panelW, top, panelW, height]);
    }

    final payload = <int>[left, top, width, height];
    for (final c in cutouts) {
      payload.addAll(c);
    }
    if (_lastHolePayload != null && _listEq(_lastHolePayload!, payload)) return;
    _lastHolePayload = payload;
    _channel.invokeMethod('setRect', {
      'left': left,
      'top': top,
      'width': width,
      'height': height,
      'cutouts': cutouts,
    });
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> play() async {
    _isCompleted = false;
    await _channel
        .invokeMethod('setProperty', {'name': 'pause', 'value': 'no'});
  }

  @override
  Future<void> pause() async {
    await _channel
        .invokeMethod('setProperty', {'name': 'pause', 'value': 'yes'});
  }

  @override
  Future<void> seekTo(Duration position) async {
    _isCompleted = false;
    await _channel.invokeMethod('command', {
      'args': ['seek', '${position.inMilliseconds / 1000.0}', 'absolute'],
    });
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _channel
        .invokeMethod('setProperty', {'name': 'speed', 'value': '$speed'});
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _channel.invokeMethod(
        'setProperty', {'name': 'volume', 'value': '${(volume * 100).round()}'});
  }

  /// 直接向原生 mpv 发命令（如 show-text OSD 反馈）。供 VideoPlayerService.mpvCommand 路由。
  Future<void> mpvCommand(List<String> args) async {
    try {
      await _channel.invokeMethod('command', {'args': args});
    } catch (_) {}
  }

  @override
  Future<void> applySuperResolutionLevel(String level) async {
    final shaders = await resolveAnime4KShaderPaths(level, native: true);
    await _channel.invokeMethod('applyShaders', {'shaders': shaders});
  }

  @override
  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isInitialized = false;
    if (_panelListener != null) {
      nativeRenderPanelFraction.removeListener(_panelListener!);
      _panelListener = null;
    }
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
  }
}

/// 铺在播放区的透明占位：不画像素（画面由原生 mpv 子窗口出），只持续把自身在
/// 窗口客户区里的物理矩形 + 控制栏上/下条高度上报给适配器，让 mpv 子窗口精确
/// 跟随视频区域、并在 Flutter 视图上按「视频 − 可见控件」挖洞。
class _NativeRenderSurface extends StatefulWidget {
  const _NativeRenderSurface({required this.adapter});
  final WindowsNativeMpvAdapter adapter;

  @override
  State<_NativeRenderSurface> createState() => _NativeRenderSurfaceState();
}

class _NativeRenderSurfaceState extends State<_NativeRenderSurface>
    with WidgetsBindingObserver {
  final _boxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleReport();
  }

  @override
  void didChangeMetrics() => _scheduleReport();

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    final ctx = _boxKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final mq = MediaQuery.of(ctx);
    final dpr = mq.devicePixelRatio;
    final origin = box.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(origin.dx * dpr, origin.dy * dpr,
        box.size.width * dpr, box.size.height * dpr);
    // 控制栏上条固定 100 逻辑 + 顶安全区；下条内容驱动 ~110-120，取 140 略宽保底。
    // 与 desktop_player_screen_state 控制栏结构对应（顶栏 height:100 / 底栏进度+按钮行）。
    final topBand = ((100 + mq.padding.top) * dpr).round();
    final botBand = ((140 + mq.padding.bottom) * dpr).round();
    widget.adapter.reportGeometry(rect, topBand, botBand);
  }

  @override
  Widget build(BuildContext context) {
    // 每帧上报一次矩形（窗口/布局变化时子窗口跟随）。透明，不遮挡逻辑。
    _scheduleReport();
    return SizedBox.expand(key: _boxKey);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
