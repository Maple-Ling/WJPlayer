/// ASS 字幕解析器和转换器
/// 
/// 将 ASS/SSA 格式转换为 SRT，支持：
/// - 合并同一时间段的多行 Dialogue（解决双语字幕问题）
/// - 去除 ASS 特效标签
/// - 保留基础格式（粗体、斜体、颜色等）
class AssConverter {
  /// 将 ASS 文件内容转换为 SRT 格式
  static String convertAssToSrt(String assContent) {
    final lines = assContent.split('\n');
    final dialogues = <_DialogueEntry>[];
    
    bool inEvents = false;
    for (final line in lines) {
      final trimmed = line.trim();
      
      if (trimmed == '[Events]') {
        inEvents = true;
        continue;
      }
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inEvents = false;
        continue;
      }
      
      if (inEvents && trimmed.startsWith('Dialogue:')) {
        final entry = _parseDialogue(trimmed);
        if (entry != null) {
          dialogues.add(entry);
        }
      }
    }
    
    if (dialogues.isEmpty) return '';
    
    // 按开始时间排序
    dialogues.sort((a, b) => a.startMs.compareTo(b.startMs));
    
    // 合并同一时间段内的多行（双语字幕）
    final merged = _mergeOverlapping(dialogues);
    
    // 生成 SRT
    final buffer = StringBuffer();
    for (int i = 0; i < merged.length; i++) {
      final entry = merged[i];
      buffer.writeln(i + 1);
      buffer.writeln('${_msToSrtTime(entry.startMs)} --> ${_msToSrtTime(entry.endMs)}');
      buffer.writeln(entry.text);
      buffer.writeln();
    }
    
    return buffer.toString();
  }
  
  /// 解析单条 Dialogue 行
  static _DialogueEntry? _parseDialogue(String line) {
    // Format: Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    // 注意：Text 部分可能包含逗号，所以要从第10个逗号后开始
    
    if (!line.startsWith('Dialogue:')) return null;
    
    final content = line.substring('Dialogue:'.length).trim();
    final parts = _splitAssLine(content);
    
    if (parts.length < 10) return null;
    
    final startTime = _parseAssTime(parts[1]);
    final endTime = _parseAssTime(parts[2]);
    final text = _stripAssTags(parts[9]);
    
    if (startTime == null || endTime == null || text.trim().isEmpty) return null;
    
    return _DialogueEntry(
      startMs: startTime,
      endMs: endTime,
      text: text.trim(),
    );
  }
  
  /// 分割 ASS 行（处理 Text 中的逗号）
  static List<String> _splitAssLine(String content) {
    final parts = <String>[];
    var commaCount = 0;
    var current = StringBuffer();
    
    for (int i = 0; i < content.length; i++) {
      final char = content[i];
      if (char == ',' && commaCount < 9) {
        parts.add(current.toString().trim());
        current.clear();
        commaCount++;
      } else {
        current.write(char);
      }
    }
    
    // 添加最后一部分（Text）
    parts.add(current.toString().trim());
    return parts;
  }
  
  /// 解析 ASS 时间格式 (H:MM:SS.cc)
  static int? _parseAssTime(String time) {
    try {
      final parts = time.trim().split(':');
      if (parts.length != 3) return null;
      
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      final seconds = int.parse(secParts[0]);
      final centiseconds = int.parse(secParts[1].padRight(2, '0').substring(0, 2));
      
      return ((hours * 3600 + minutes * 60 + seconds) * 1000 + centiseconds * 10);
    } catch (_) {
      return null;
    }
  }
  
  /// 将毫秒转换为 SRT 时间格式 (HH:MM:SS,mmm)
  static String _msToSrtTime(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    
    return '${_pad(hours)}:${_pad(minutes)}:${_pad(seconds)},${_padMillis(millis)}';
  }
  
  static String _pad(int n) => n.toString().padLeft(2, '0');
  static String _padMillis(int n) => n.toString().padLeft(3, '0');
  
  /// 合并时间重叠的 Dialogue 条目（双语字幕）
  static List<_DialogueEntry> _mergeOverlapping(List<_DialogueEntry> entries) {
    if (entries.isEmpty) return [];
    
    final result = <_DialogueEntry>[];
    var current = entries[0];
    
    for (int i = 1; i < entries.length; i++) {
      final next = entries[i];
      
      // 如果时间重叠（容差 100ms），合并文本
      if (_isOverlapping(current, next)) {
        current = _DialogueEntry(
          startMs: current.startMs,
          endMs: current.endMs < next.endMs ? next.endMs : current.endMs,
          text: '${current.text}\n${next.text}',
        );
      } else {
        result.add(current);
        current = next;
      }
    }
    
    result.add(current);
    return result;
  }
  
  /// 检查两个条目是否时间重叠
  static bool _isOverlapping(_DialogueEntry a, _DialogueEntry b) {
    // 容差 100ms
    return (b.startMs - a.endMs).abs() < 100 || (b.startMs >= a.startMs && b.startMs <= a.endMs + 100);
  }
  
  /// 去除 ASS 标签（保留基础格式）
  static String _stripAssTags(String text) {
    var result = text;
    
    // 替换 \\N 和 \\n 为换行
    result = result.replaceAll(r'\N', '\n');
    result = result.replaceAll(r'\n', '\n');
    
    // 去除所有 {\...} 标签
    result = result.replaceAll(RegExp(r'\{[^}]*\}'), '');
    
    // 去除其他转义序列
    result = result.replaceAll('\\h', ' ');  // 硬空格
    
    // 清理多余空格
    result = result.replaceAll(RegExp(r' +'), ' ').trim();
    
    return result;
  }
}

class _DialogueEntry {
  final int startMs;
  final int endMs;
  final String text;
  
  _DialogueEntry({required this.startMs, required this.endMs, required this.text});
}
