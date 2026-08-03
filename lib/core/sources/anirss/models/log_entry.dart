/// 一条运行日志（`/api/logs` 的 `Log`）。下载日志（`/api/downloadLogs`）为纯文本，不走此模型。
class LogEntryModel {
  final String message;
  final String? level;
  final String? loggerName;
  final String? threadName;

  const LogEntryModel({
    this.message = '',
    this.level,
    this.loggerName,
    this.threadName,
  });

  static LogEntryModel fromJson(Map<String, dynamic> m) => LogEntryModel(
        message: m['message']?.toString() ?? '',
        level: m['level']?.toString(),
        loggerName: m['loggerName']?.toString(),
        threadName: m['threadName']?.toString(),
      );

  /// 日志级别归一（大写），缺省 INFO。
  String get levelLabel => (level == null || level!.isEmpty)
      ? 'INFO'
      : level!.toUpperCase();

  bool get isError => levelLabel == 'ERROR' || levelLabel == 'FATAL';
  bool get isWarn => levelLabel == 'WARN' || levelLabel == 'WARNING';

  /// 短类名（去包名前缀），用于副标题展示。
  String? get shortLogger {
    final n = loggerName;
    if (n == null || n.isEmpty) return null;
    final dot = n.lastIndexOf('.');
    return dot >= 0 ? n.substring(dot + 1) : n;
  }
}
