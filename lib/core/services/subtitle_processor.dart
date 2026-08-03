import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'app_logger.dart';

/// 字幕处理器
///
/// 在 Dart 层处理字幕文件，实现：
/// - 时间轴偏移（字幕延迟/提前）
/// - ASS 样式修改（字体、大小、位置）
/// - 格式转换
class SubtitleProcessor {
  static final _logger = AppLogger();

  /// 将 ASS/SSA 字幕转换为 SRT，供不支持 ASS 特效的播放器兜底使用。
  static Future<String> convertAssToSrt(
    String inputPath, {
    String? outputPath,
  }) async {
    final inputFile = File(inputPath);
    if (!inputFile.existsSync()) {
      throw Exception('字幕文件不存在: $inputPath');
    }

    final ext = inputPath.split('.').last.toLowerCase();
    if (ext != 'ass' && ext != 'ssa') {
      _logger.w('SubtitleProcessor', '仅支持 ASS/SSA 转 SRT，当前格式: $ext');
      return inputPath;
    }

    _logger.i('SubtitleProcessor', '开始将 ASS/SSA 转换为 SRT: $inputPath');

    final content = await inputFile.readAsString();
    final converted = _convertAssContentToSrt(content);
    final outPath = outputPath ?? await _generateTempPathWithExtension(inputPath, '_converted', 'srt');
    await File(outPath).writeAsString(converted);

    _logger.i('SubtitleProcessor', 'ASS/SSA 已转换为 SRT: $outPath');
    return outPath;
  }

  /// 调整字幕时间轴
  ///
  /// [inputPath] 原始字幕文件路径
  /// [offsetSeconds] 偏移秒数（正值=延后，负值=提前）
  /// [outputPath] 输出文件路径（可选，默认生成临时文件）
  /// 返回处理后的文件路径
  static Future<String> adjustTiming(
    String inputPath,
    double offsetSeconds, {
    String? outputPath,
  }) async {
    if (offsetSeconds == 0.0) {
      return inputPath;
    }

    _logger.i('SubtitleProcessor', '调整字幕时间轴: offset=${offsetSeconds}s');

    final inputFile = File(inputPath);
    if (!inputFile.existsSync()) {
      throw Exception('字幕文件不存在: $inputPath');
    }

    final content = await inputFile.readAsString();
    final ext = inputPath.split('.').last.toLowerCase();

    String processedContent;
    switch (ext) {
      case 'srt':
        processedContent = _adjustSrtTiming(content, offsetSeconds);
      case 'ass':
      case 'ssa':
        processedContent = _adjustAssTiming(content, offsetSeconds);
      case 'vtt':
        processedContent = _adjustVttTiming(content, offsetSeconds);
      default:
        _logger.w('SubtitleProcessor', '不支持的格式: $ext，跳过调整');
        return inputPath;
    }

    // 生成输出路径
    final outPath = outputPath ?? await _generateTempPath(inputPath, '_adjusted');
    final outFile = File(outPath);
    await outFile.writeAsString(processedContent);

    _logger.i('SubtitleProcessor', '字幕已调整并保存: $outPath');
    return outPath;
  }

  /// 修改 ASS 字幕样式
  ///
  /// [inputPath] 原始 ASS 文件路径
  /// [fontName] 字体名称
  /// [fontSize] 字体大小（像素）
  /// [marginV] 垂直边距（控制字幕位置）
  static Future<String> modifyAssStyle(
    String inputPath, {
    String? fontName,
    int? fontSize,
    int? marginV,
  }) async {
    _logger.i('SubtitleProcessor', '修改 ASS 样式: font=$fontName, size=$fontSize, marginV=$marginV');

    final file = File(inputPath);
    if (!file.existsSync()) {
      throw Exception('字幕文件不存在: $inputPath');
    }

    var content = await file.readAsString();

    // 修改 [V4+ Styles] 中的 Default 样式
    if (fontName != null || fontSize != null || marginV != null) {
      content = _modifyAssStyleSection(
        content,
        fontName: fontName,
        fontSize: fontSize,
        marginV: marginV,
      );
    }

    final outPath = await _generateTempPath(inputPath, '_styled');
    final outFile = File(outPath);
    await outFile.writeAsString(content);

    _logger.i('SubtitleProcessor', 'ASS 样式已修改并保存: $outPath');
    return outPath;
  }

  /// 检测字幕格式
  static String detectFormat(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'srt':
        return 'subrip';
      case 'ass':
      case 'ssa':
        return 'ass';
      case 'vtt':
        return 'webvtt';
      case 'pgs':
        return 'pgs';
      case 'sup':
        return 'sup';
      default:
        return 'unknown';
    }
  }

  /// 检测是否为图形字幕（PGS/SUP）
  static bool isGraphicalSubtitle(String filePath) {
    final format = detectFormat(filePath);
    return format == 'pgs' || format == 'sup';
  }

  /// 生成临时文件路径
  static Future<String> _generateTempPath(String originalPath, String suffix) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = originalPath.split('/').last;
    final baseName = fileName.substring(0, fileName.lastIndexOf('.'));
    final ext = fileName.split('.').last;
    return '${tempDir.path}/$baseName$suffix.$ext';
  }

  static Future<String> _generateTempPathWithExtension(
    String originalPath,
    String suffix,
    String ext,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = originalPath.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    final baseName = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    return '${tempDir.path}/$baseName$suffix.$ext';
  }

  // ========== SRT 时间轴调整 ==========
  static String _adjustSrtTiming(String content, double offsetSeconds) {
    final lines = content.split('\n');
    final result = <String>[];

    final timeRegex = RegExp(
      r'(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*--\u003e\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})',
    );

    for (final line in lines) {
      final match = timeRegex.firstMatch(line);
      if (match != null) {
        final startTime = _parseSrtTime(match, 1);
        final endTime = _parseSrtTime(match, 5);

        final adjustedStart = startTime + offsetSeconds;
        final adjustedEnd = endTime + offsetSeconds;

        if (adjustedStart >= 0 && adjustedEnd >= 0) {
          result.add(
            '${_formatSrtTime(adjustedStart)} --> ${_formatSrtTime(adjustedEnd)}',
          );
        } else {
          result.add(line);
        }
      } else {
        result.add(line);
      }
    }

    return result.join('\n');
  }

  static double _parseSrtTime(RegExpMatch match, int startGroup) {
    final hours = int.parse(match.group(startGroup)!);
    final minutes = int.parse(match.group(startGroup + 1)!);
    final seconds = int.parse(match.group(startGroup + 2)!);
    final millis = int.parse(match.group(startGroup + 3)!);
    return hours * 3600 + minutes * 60 + seconds + millis / 1000.0;
  }

  static String _formatSrtTime(double totalSeconds) {
    final hours = (totalSeconds / 3600).floor();
    final minutes = ((totalSeconds % 3600) / 60).floor();
    final seconds = (totalSeconds % 60).floor();
    final millis = ((totalSeconds - totalSeconds.floor()) * 1000).round();
    return '${_pad2(hours)}:${_pad2(minutes)}:${_pad2(seconds)},${_pad3(millis)}';
  }

  // ========== ASS/SSA 时间轴调整 ==========
  static String _adjustAssTiming(String content, double offsetSeconds) {
    final lines = content.split('\n');
    final result = <String>[];

    // ASS Dialogue 行格式：Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    final dialogueRegex = RegExp(
      r'^(Dialogue:\s*\d+,)(\d+:\d+:\d+\.\d+)(,)(\d+:\d+:\d+\.\d+)(,.*)$',
    );

    for (final line in lines) {
      final match = dialogueRegex.firstMatch(line);
      if (match != null) {
        final prefix = match.group(1)!;
        final startTime = match.group(2)!;
        final separator = match.group(3)!;
        final endTime = match.group(4)!;
        final suffix = match.group(5)!;

        final startSeconds = _parseAssTime(startTime);
        final endSeconds = _parseAssTime(endTime);

        final adjustedStart = startSeconds + offsetSeconds;
        final adjustedEnd = endSeconds + offsetSeconds;

        if (adjustedStart >= 0 && adjustedEnd >= 0) {
          result.add(
            '$prefix${_formatAssTime(adjustedStart)}$separator${_formatAssTime(adjustedEnd)}$suffix',
          );
        } else {
          result.add(line);
        }
      } else {
        result.add(line);
      }
    }

    return result.join('\n');
  }

  static double _parseAssTime(String time) {
    final parts = time.split(':');
    final hours = double.parse(parts[0]);
    final minutes = double.parse(parts[1]);
    final seconds = double.parse(parts[2]);
    return hours * 3600 + minutes * 60 + seconds;
  }

  static String _formatAssTime(double totalSeconds) {
    if (totalSeconds < 0) totalSeconds = 0;
    final hours = (totalSeconds / 3600).floor();
    final minutes = ((totalSeconds % 3600) / 60).floor();
    final seconds = totalSeconds % 60;
    return '${_pad2(hours)}:${_pad2(minutes)}:${seconds.toStringAsFixed(2)}';
  }

  // ========== WebVTT 时间轴调整 ==========
  static String _adjustVttTiming(String content, double offsetSeconds) {
    final lines = content.split('\n');
    final result = <String>[];

    final timeRegex = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s*--\u003e\s*(\d{2}):(\d{2}):(\d{2})\.(\d{3})',
    );

    for (final line in lines) {
      final match = timeRegex.firstMatch(line);
      if (match != null) {
        final startTime = _parseSrtTime(match, 1);
        final endTime = _parseSrtTime(match, 5);

        final adjustedStart = startTime + offsetSeconds;
        final adjustedEnd = endTime + offsetSeconds;

        if (adjustedStart >= 0 && adjustedEnd >= 0) {
          result.add(
            '${_formatVttTime(adjustedStart)} --> ${_formatVttTime(adjustedEnd)}',
          );
        } else {
          result.add(line);
        }
      } else {
        result.add(line);
      }
    }

    return result.join('\n');
  }

  static String _formatVttTime(double totalSeconds) {
    final hours = (totalSeconds / 3600).floor();
    final minutes = ((totalSeconds % 3600) / 60).floor();
    final seconds = (totalSeconds % 60).floor();
    final millis = ((totalSeconds - totalSeconds.floor()) * 1000).round();
    return '${_pad2(hours)}:${_pad2(minutes)}:${_pad2(seconds)}.${_pad3(millis)}';
  }

  // ========== ASS 样式修改 ==========
  static String _modifyAssStyleSection(
    String content, {
    String? fontName,
    int? fontSize,
    int? marginV,
  }) {
    final lines = content.split('\n');
    final result = <String>[];
    var inStyleSection = false;

    for (final line in lines) {
      if (line.trim() == '[V4+ Styles]') {
        inStyleSection = true;
        result.add(line);
        continue;
      }

      if (inStyleSection && line.trim().startsWith('[') && line.trim() != '[V4+ Styles]') {
        inStyleSection = false;
      }

      if (inStyleSection && line.trim().startsWith('Style:')) {
        result.add(_modifyStyleLine(line, fontName: fontName, fontSize: fontSize, marginV: marginV));
      } else {
        result.add(line);
      }
    }

    return result.join('\n');
  }

  static String _modifyStyleLine(
    String line, {
    String? fontName,
    int? fontSize,
    int? marginV,
  }) {
    // Style: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,
    // Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,
    // Alignment,MarginL,MarginR,MarginV,Encoding
    final parts = line.split(',');
    if (parts.length < 23) return line;

    if (fontName != null) {
      parts[1] = fontName;
    }
    if (fontSize != null) {
      parts[2] = fontSize.toString();
    }
    if (marginV != null && parts.length > 22) {
      parts[22] = marginV.toString();
    }

    return parts.join(',');
  }

  static String _convertAssContentToSrt(String content) {
    final lines = content.split('\n');
    final srtEntries = <String>[];

    var inEventsSection = false;
    var eventFormat = <String>[];
    var cueIndex = 1;

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final trimmed = line.trimLeft();

      if (trimmed.startsWith('[')) {
        inEventsSection = trimmed == '[Events]';
        continue;
      }

      if (!inEventsSection) continue;

      if (trimmed.startsWith('Format:')) {
        eventFormat = trimmed
            .substring('Format:'.length)
            .split(',')
            .map((part) => part.trim())
            .toList();
        continue;
      }

      if (!trimmed.startsWith('Dialogue:')) continue;

      final dialogueBody = trimmed.substring('Dialogue:'.length).trimLeft();
      final fields = _splitAssFields(
        dialogueBody,
        eventFormat.isNotEmpty ? eventFormat.length : 10,
      );
      if (fields.length < 3) continue;

      final startIndex = eventFormat.isNotEmpty ? eventFormat.indexOf('Start') : 1;
      final endIndex = eventFormat.isNotEmpty ? eventFormat.indexOf('End') : 2;
      final textIndex = eventFormat.isNotEmpty ? eventFormat.indexOf('Text') : 9;
      if (startIndex < 0 || endIndex < 0 || textIndex < 0) continue;
      if (fields.length <= startIndex || fields.length <= endIndex || fields.length <= textIndex) {
        continue;
      }

      final text = _stripAssToPlainText(fields[textIndex]);
      if (text.isEmpty) continue;

      final start = _formatSrtTime(_parseAssTime(fields[startIndex].trim()));
      final end = _formatSrtTime(_parseAssTime(fields[endIndex].trim()));
      srtEntries.add('$cueIndex\n$start --> $end\n$text');
      cueIndex++;
    }

    if (srtEntries.isEmpty) {
      _logger.w('SubtitleProcessor', 'ASS/SSA 转 SRT 未解析到有效对白，输出空字幕');
      return '';
    }

    return '${srtEntries.join('\n\n')}\n';
  }

  static List<String> _splitAssFields(String input, int expectedFields) {
    if (expectedFields <= 1) return [input];

    final result = <String>[];
    var start = 0;
    var commasFound = 0;

    for (var i = 0; i < input.length; i++) {
      if (input.codeUnitAt(i) != 44) continue;
      if (commasFound >= expectedFields - 1) break;
      result.add(input.substring(start, i));
      start = i + 1;
      commasFound++;
    }

    result.add(input.substring(start));
    return result;
  }

  static String _stripAssToPlainText(String text) {
    var result = text;
    result = result.replaceAll('\r', '');
    result = result.replaceAll('\\N', '\n');
    result = result.replaceAll('\\n', '\n');
    result = result.replaceAll(RegExp(r'\{[^}]*\}'), '');
    result = result.replaceAll(RegExp(r'[^\S\n]+'), ' ');
    result = result
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return result.trim();
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
  static String _pad3(int n) => n.toString().padLeft(3, '0');
}
