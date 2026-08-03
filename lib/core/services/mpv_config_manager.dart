import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'app_logger.dart';

/// MPV 配置管理器
///
/// 负责管理 mpv 配置文件（mpv.conf）和字体目录。
///
/// ⚠️ 注意：media_kit 默认不读取 mpv.conf（config=no）。
/// mpv.conf 中的配置项不会被 media_kit Player 实例消费。
/// 所有运行时属性必须通过 NativePlayer.setProperty() 设置才生效。
/// mpv.conf 仅作为配置意图的持久化记录，供未来可能的手动调试使用。
///
/// fontsDirectory 属性用于设置 sub-fonts-dir 运行时属性。
class MpvConfigManager {
  static final _logger = AppLogger();
  static final _instance = MpvConfigManager._internal();
  factory MpvConfigManager() => _instance;
  MpvConfigManager._internal();

  String? _configDir;
  String? _fontsDir;

  /// 初始化配置目录
  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();
    _configDir = appDir.path;
    _fontsDir = '${appDir.path}/fonts';

    // 确保字体目录存在
    final fontsDir = Directory(_fontsDir!);
    if (!fontsDir.existsSync()) {
      fontsDir.createSync(recursive: true);
    }

    _logger.i('MpvConfig', '配置目录: $_configDir');
    _logger.i('MpvConfig', '字体目录: $_fontsDir');
  }

  /// 获取 mpv.conf 路径
  String get configFilePath => '$_configDir/mpv.conf';

  /// 获取字体目录路径
  String get fontsDirectory => _fontsDir!;

  /// 写入 mpv 配置文件
  ///
  /// [subtitleFont] 字幕字体名称
  /// [subtitleScale] 字幕缩放比例（1.0 = 默认）
  /// [subtitlePosition] 字幕位置（0-100, 100=底部）
  /// [subtitleDelay] 字幕延迟（秒，正值=延后）
  /// [audioDelay] 音频延迟（秒，正值=延后）
  /// [aspectRatio] 画面比例（如 "16:9", "4:3", "-1"=自动）
  /// [glslShaders] GLSL shader 路径（Anime4K 等）
  /// [subtitleBackground] 字幕黑色背景
  Future<void> writeConfig({
    String? subtitleFont,
    double subtitleScale = 1.0,
    double subtitlePosition = 100.0,
    double subtitleDelay = 0.0,
    double audioDelay = 0.0,
    String? aspectRatio,
    List<String>? glslShaders,
    bool subtitleBackground = false,
  }) async {
    if (_configDir == null) {
      await initialize();
    }

    final buffer = StringBuffer();
    buffer.writeln('# WJPlayer MPV 配置文件');
    buffer.writeln('# 由 MpvConfigManager 自动生成');
    buffer.writeln();

    // 字体设置
    if (_fontsDir != null) {
      buffer.writeln('# 字体目录');
      buffer.writeln('sub-fonts-dir="$_fontsDir"');
    }

    if (subtitleFont != null && subtitleFont.isNotEmpty) {
      buffer.writeln('# 字幕字体');
      buffer.writeln('sub-font="$subtitleFont"');
    }

    // 字幕大小
    if (subtitleScale != 1.0) {
      buffer.writeln('# 字幕缩放');
      buffer.writeln('sub-scale=$subtitleScale');
    }

    // 字幕位置
    if (subtitlePosition != 100.0) {
      buffer.writeln('# 字幕位置 (0=顶部, 100=底部)');
      buffer.writeln('sub-pos=${subtitlePosition.round()}'); // mpv sub-pos 只收整数
    }

    // 字幕延迟
    if (subtitleDelay != 0.0) {
      buffer.writeln('# 字幕延迟 (秒)');
      buffer.writeln('sub-delay=${subtitleDelay.toStringAsFixed(3)}');
    }

    // 音频延迟
    if (audioDelay != 0.0) {
      buffer.writeln('# 音频延迟 (秒)');
      buffer.writeln('audio-delay=${audioDelay.toStringAsFixed(3)}');
    }

    // 画面比例
    if (aspectRatio != null && aspectRatio.isNotEmpty) {
      String value;
      switch (aspectRatio) {
        case '16:9':
          value = '16/9';
        case '4:3':
          value = '4/3';
        case '21:9':
          value = '21/9';
        case '全屏':
          value = '0';
        case '原始':
          value = '0';
        default:
          // 自适应/自动不强制覆盖容器比例，交给 mpv 按媒体原始 DAR 渲染。
          value = '0';
      }
      buffer.writeln('# 画面比例');
      buffer.writeln('video-aspect-override=$value');
    }

    // Anime4K shaders are applied at runtime through NativePlayer commands.
    // Persisting the raw shader list here can make Windows mpv treat the
    // whole joined string as a single file path during startup.
    if (glslShaders != null && glslShaders.isNotEmpty) {
      buffer.writeln('# Anime4K shaders are applied at runtime');
    }

    // 字幕黑色背景
    if (subtitleBackground) {
      buffer.writeln('# 字幕黑色背景');
      buffer.writeln('sub-back-color=#000000C0');
    } else {
      buffer.writeln('# 字幕背景透明');
      buffer.writeln('sub-back-color=#00000000');
    }

    // 通用优化设置
    buffer.writeln();
    buffer.writeln('# 通用设置');
    buffer.writeln('vo=gpu');
    buffer.writeln('hwdec=auto');
    buffer.writeln('cache=yes');
    buffer.writeln('cache-secs=30');
    buffer.writeln('demuxer-max-bytes=50M');
    buffer.writeln('demuxer-max-back-bytes=25M');
    buffer.writeln('sub-auto=fuzzy');
    buffer.writeln('sub-visibility=yes');
    buffer.writeln('sub-ass=yes');
    buffer.writeln('sub-ass-override=no');
    buffer.writeln('sub-scale-by-window=no');
    buffer.writeln('sub-scale-with-window=no');
    buffer.writeln('sub-ass-scale-with-window=no');
    buffer.writeln('sub-use-margins=yes');
    buffer.writeln('sub-ass-force-margins=yes');
    buffer.writeln('slang=chi,zh,eng,en');
    // 字幕走 OSD 覆盖层渲染，不混入视频帧。
    // blend-subtitles=video 会让 PGS/SUP 位图字幕的每次刷新都重绘整帧，
    // 在 libmpv 渲染 API + 硬解路径下导致画面闪现，因此默认关闭。
    buffer.writeln('blend-subtitles=no');

    final configPath = configFilePath;
    final file = File(configPath);
    await file.writeAsString(buffer.toString());

    _logger.i('MpvConfig', '配置文件已写入: $configPath');
    _logger.d('MpvConfig', '内容:\n${buffer.toString()}');
  }

  /// 读取当前配置文件内容
  Future<String> readConfig() async {
    if (_configDir == null) {
      await initialize();
    }
    final file = File(configFilePath);
    if (file.existsSync()) {
      return file.readAsString();
    }
    return '';
  }

  /// 更新单个配置项（覆盖整个文件）
  Future<void> updateConfigValue(String key, String value) async {
    final currentConfig = await readConfig();
    final lines = currentConfig.split('\n');
    final newLines = <String>[];
    var found = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('$key=')) {
        newLines.add('$key=$value');
        found = true;
      } else {
        newLines.add(line);
      }
    }

    if (!found) {
      newLines.add('$key=$value');
    }

    final file = File(configFilePath);
    await file.writeAsString(newLines.join('\n'));
    _logger.i('MpvConfig', '配置已更新: $key=$value');
  }
}
