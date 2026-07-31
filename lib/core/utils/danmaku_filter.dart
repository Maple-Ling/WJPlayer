import 'package:xml/xml.dart';

/// 弹幕屏蔽词过滤器
/// 
/// 支持两种类型的屏蔽：
/// - 文本屏蔽：检查弹幕内容是否包含屏蔽词
/// - 用户屏蔽：检查弹幕发送者ID是否在屏蔽列表中
class DanmakuFilter {
  final List<String> _textBlockwords = [];
  final List<String> _userBlocklist = [];

  /// 添加文本屏蔽词
  void addTextBlockword(String word) {
    if (word.isNotEmpty && !_textBlockwords.contains(word)) {
      _textBlockwords.add(word);
    }
  }

  /// 添加用户ID到屏蔽列表
  void addUserBlock(String userId) {
    if (userId.isNotEmpty && !_userBlocklist.contains(userId)) {
      _userBlocklist.add(userId);
    }
  }

  /// 移除文本屏蔽词
  void removeTextBlockword(String word) {
    _textBlockwords.remove(word);
  }

  /// 移除用户屏蔽
  void removeUserBlock(String userId) {
    _userBlocklist.remove(userId);
  }

  /// 批量导入屏蔽词
  void importBlockwords(List<String> words) {
    for (final word in words) {
      addTextBlockword(word);
    }
  }

  /// 批量导入用户屏蔽
  void importUserBlocks(List<String> userIds) {
    for (final userId in userIds) {
      addUserBlock(userId);
    }
  }

  /// 检查弹幕是否应该被过滤
  /// 
  /// [text] 弹幕文本内容
  /// [userId] 发送者用户ID（可选）
  bool shouldFilter(String text, {String? userId}) {
    // 检查用户是否在屏蔽列表
    if (userId != null && _userBlocklist.contains(userId)) {
      return true;
    }

    // 检查文本是否包含屏蔽词
    for (final word in _textBlockwords) {
      if (text.contains(word)) {
        return true;
      }
    }

    return false;
  }

  /// 过滤弹幕列表
  List<T> filterDanmakuList<T>(
    List<T> danmakuList,
    String Function(T) textExtractor, {
    String Function(T)? userIdExtractor,
  }) {
    return danmakuList.where((item) {
      final text = textExtractor(item);
      final userId = userIdExtractor != null ? userIdExtractor(item) : null;
      return !shouldFilter(text, userId: userId);
    }).toList();
  }

  /// 清空所有屏蔽词
  void clear() {
    _textBlockwords.clear();
    _userBlocklist.clear();
  }

  /// 获取文本屏蔽词列表
  List<String> get textBlockwords => List.unmodifiable(_textBlockwords);

  /// 获取用户屏蔽列表
  List<String> get userBlocklist => List.unmodifiable(_userBlocklist);

  /// 获取屏蔽词总数
  int get totalBlockCount => _textBlockwords.length + _userBlocklist.length;

  /// 从弹弹play XML格式导入屏蔽词
  /// 
  /// 弹弹play XML格式示例：
  /// <item enabled="true">t=屏蔽词</item>
  /// <item enabled="true">x=uid=[平台]用户ID</item>
  static DanmakuFilterImportResult importFromDandanplayXml(String xmlContent) {
    final filter = DanmakuFilter();
    final textWords = <String>[];
    final userIds = <String>[];
    int skippedCount = 0;

    try {
      final document = XmlDocument.parse(xmlContent);
      final items = document.findAllElements('item');

      for (final item in items) {
        // 检查 enabled 属性
        final enabled = item.getAttribute('enabled');
        if (enabled == 'false') {
          skippedCount++;
          continue;
        }

        final content = (item.value ?? '').trim();
        if (content.isEmpty) {
          skippedCount++;
          continue;
        }

        if (content.startsWith('t=')) {
          // 文本屏蔽词
          final word = content.substring(2).trim();
          if (word.isNotEmpty) {
            textWords.add(word);
            filter.addTextBlockword(word);
          }
        } else if (content.startsWith('x=uid=')) {
          // 用户ID屏蔽
          final userId = content.substring(6).trim();
          if (userId.isNotEmpty) {
            userIds.add(userId);
            filter.addUserBlock(userId);
          }
        }
      }
    } catch (e) {
      throw Exception('解析 XML 失败: $e');
    }

    return DanmakuFilterImportResult(
      filter: filter,
      textWords: textWords,
      userIds: userIds,
      skippedCount: skippedCount,
    );
  }
}

/// 屏蔽词导入结果
class DanmakuFilterImportResult {
  final DanmakuFilter filter;
  final List<String> textWords;
  final List<String> userIds;
  final int skippedCount;

  const DanmakuFilterImportResult({
    required this.filter,
    required this.textWords,
    required this.userIds,
    required this.skippedCount,
  });

  /// 导入的总数
  int get totalImported => textWords.length + userIds.length;
}
