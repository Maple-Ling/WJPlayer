import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/log_entry.dart';

/// 打开 Ani-rss「诊断与维护」页（移动/桌面共用 Material 主体）。
Future<void> showAniRssDiagnostics(BuildContext context, WidgetRef ref) {
  final api = ref.read(aniRssApiProvider);
  if (api == null) return Future.value();
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('诊断与维护')),
        body: AniRssDiagnosticsBody(api: api),
      ),
    ),
  );
}

/// 诊断与维护主体：连接/维护操作 + 运行日志 + 下载日志 + 服务管理。
class AniRssDiagnosticsBody extends ConsumerStatefulWidget {
  final AniRssApi api;
  const AniRssDiagnosticsBody({super.key, required this.api});

  @override
  ConsumerState<AniRssDiagnosticsBody> createState() =>
      _AniRssDiagnosticsBodyState();
}

class _AniRssDiagnosticsBodyState extends ConsumerState<AniRssDiagnosticsBody> {
  AniRssApi get api => widget.api;

  bool _logsLoading = false;
  String? _logsError;
  List<LogEntryModel> _logs = const [];
  String? _busyAction;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() {
      _logsLoading = true;
      _logsError = null;
    });
    try {
      final l = await api.logs();
      if (mounted) {
        setState(() {
          _logs = l;
          _logsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _logsError = '$e';
          _logsLoading = false;
        });
      }
    }
  }

  Future<void> _run(String key, String busy, Future<void> Function() task,
      {required String ok}) async {
    if (_busyAction != null) return;
    setState(() => _busyAction = key);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(busy)));
    try {
      await task();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(ok)));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('失败：$e')));
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _exportConfig() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await api.exportConfigUrl();
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
          const SnackBar(content: Text('已复制导出链接，可在浏览器打开下载')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('获取导出链接失败：$e')));
    }
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停止 Ani-rss 服务？'),
        content: const Text('将停止服务端进程，停止后需在服务器端手动重启。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('停止', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _run('stop', '正在停止服务…', () => api.stop(), ok: '已发送停止指令');
  }

  Future<void> _showDownloadLogs() async {
    final messenger = ScaffoldMessenger.of(context);
    String text;
    try {
      text = await api.downloadLogs();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('读取下载日志失败：$e')));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载日志'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '（暂无下载日志）' : text,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        _sectionTitle('连接 / 维护'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionChip('ping', Icons.wifi_tethering, '存活测试',
                    () => _run('ping', '测试中…', api.ping, ok: '服务在线')),
                _actionChip('dl', Icons.download_done_outlined, '下载器测试',
                    () async {
                  await _run('dl', '测试下载器…', () async {
                    final cfg = await api.config();
                    await api.downloadLoginTest(cfg);
                  }, ok: '下载器连接正常');
                }),
                _actionChip('ip', Icons.shield_outlined, 'IP 白名单测试',
                    () => _run('ip', '测试中…', api.testIpWhitelist, ok: '白名单测试通过')),
                _actionChip('cache', Icons.cleaning_services_outlined, '清理缓存',
                    () => _run('cache', '清理中…', api.clearCache, ok: '缓存已清理')),
                _actionChip('export', Icons.file_download_outlined, '导出设置链接',
                    _exportConfig),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _sectionTitle('服务管理'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.system_update_alt_outlined),
                title: const Text('检查并更新 Ani-rss'),
                subtitle: const Text('触发服务端自更新到最新版本'),
                trailing: _busyAction == 'update'
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right),
                onTap: () =>
                    _run('update', '正在触发更新…', api.update, ok: '已触发更新（稍后服务端重启）'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.power_settings_new, color: Colors.red),
                title: const Text('停止服务', style: TextStyle(color: Colors.red)),
                subtitle: const Text('停止 Ani-rss 服务端进程'),
                onTap: _confirmStop,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _sectionTitle('运行日志')),
            TextButton.icon(
              onPressed: _showDownloadLogs,
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('下载日志'),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _logsLoading ? null : _loadLogs,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '清空日志',
              onPressed: () => _run('clearLogs', '清空中…', () async {
                await api.clearLogs();
                await _loadLogs();
              }, ok: '日志已清空'),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        _logsCard(),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Text(t,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );

  Widget _actionChip(
      String key, IconData icon, String label, VoidCallback onTap) {
    final busy = _busyAction == key;
    return ActionChip(
      avatar: busy
          ? const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 18),
      label: Text(label),
      onPressed: _busyAction != null ? null : onTap,
    );
  }

  Widget _logsCard() {
    if (_logsLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_logsError != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('读取日志失败：$_logsError'),
        ),
      );
    }
    if (_logs.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final log in _logs.reversed.take(200))
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: _levelDot(log),
              title: Text(log.message,
                  style: const TextStyle(fontSize: 12.5),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis),
              subtitle: log.shortLogger != null
                  ? Text('${log.levelLabel} · ${log.shortLogger}',
                      style: const TextStyle(fontSize: 10))
                  : Text(log.levelLabel,
                      style: const TextStyle(fontSize: 10)),
            ),
        ],
      ),
    );
  }

  Widget _levelDot(LogEntryModel log) {
    final color = log.isError
        ? Colors.red
        : (log.isWarn ? Colors.orange : Colors.green);
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
