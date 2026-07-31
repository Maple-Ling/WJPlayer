part of 'settings_screen.dart';

/// 追番/观看记录同步设置页（移动端 + 桌面端共用）。
///
/// 提供 Trakt（设备码登录）与 Bangumi（授权码粘贴登录）两个选项。
class SyncSettingsScreen extends ConsumerWidget {
  const SyncSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('同步服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              '将观看记录同步到第三方追踪服务。连接后，播放完成的影片/剧集会标记到对应账号。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          _SyncServiceTile(
            service: SyncService.trakt,
            account: state.trakt,
            icon: Icons.movie_outlined,
            description: '电影与剧集追踪（trakt.tv）',
          ),
          const SizedBox(height: 12),
          _SyncServiceTile(
            service: SyncService.bangumi,
            account: state.bangumi,
            icon: Icons.animation_outlined,
            description: '动画/番剧追踪（bgm.tv）',
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.rocket_launch_outlined, size: 28),
              title: const Text('Bangumi 国内加速'),
              subtitle: const Text(
                '通过反代访问 Bangumi 接口与图片，国内更快更稳；关闭则直连官方 api.bgm.tv。',
                style: TextStyle(fontSize: 12),
              ),
              value: ref.watch(bangumiMirrorProvider),
              onChanged: (v) =>
                  ref.read(bangumiMirrorProvider.notifier).state = v,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncServiceTile extends ConsumerWidget {
  final SyncService service;
  final SyncAccount? account;
  final IconData icon;
  final String description;

  const _SyncServiceTile({
    required this.service,
    required this.account,
    required this.icon,
    required this.description,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = account != null;
    final subtitle = connected
        ? '已连接${account!.username != null ? '：${account!.username}' : ''}'
        : description;
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 32),
        title: Text(service.displayName),
        subtitle: Text(subtitle),
        trailing: connected
            ? OutlinedButton(
                onPressed: () => _disconnect(context, ref),
                child: const Text('断开'),
              )
            : FilledButton(
                onPressed: () => _connect(context, ref),
                child: const Text('连接'),
              ),
      ),
    );
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('断开 ${service.displayName}'),
        content: const Text('确定要断开连接吗？已保存的登录令牌会被清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(syncControllerProvider.notifier).disconnect(service);
    }
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final connected = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => service == SyncService.trakt
          ? const _TraktConnectDialog()
          : const _BangumiConnectDialog(),
    );
    if (connected == true && context.mounted) {
      AppToast.show(context, '${service.displayName} 已连接');
    }
  }
}

// ============ Trakt 设备码登录对话框 ============

class _TraktConnectDialog extends ConsumerStatefulWidget {
  const _TraktConnectDialog();

  @override
  ConsumerState<_TraktConnectDialog> createState() =>
      _TraktConnectDialogState();
}

class _TraktConnectDialogState extends ConsumerState<_TraktConnectDialog> {
  TraktDeviceCode? _code;
  String? _error;
  String _status = '正在获取授权码…';
  Timer? _pollTimer;
  int _remaining = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final code =
          await ref.read(syncControllerProvider.notifier).startTraktDeviceAuth();
      if (!mounted) return;
      setState(() {
        _code = code;
        _remaining = code.expiresIn;
        _status = '请在浏览器打开下方网址并输入验证码';
      });
      _beginPolling(code);
    } catch (e) {
      if (mounted) setState(() => _error = '获取授权码失败：$e');
    }
  }

  void _beginPolling(TraktDeviceCode code) {
    var interval = code.interval;
    var tick = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) return;
      setState(() => _remaining = (_remaining - 1).clamp(0, code.expiresIn));
      if (_remaining <= 0) {
        timer.cancel();
        setState(() => _error = '授权码已过期，请重试');
        return;
      }
      tick++;
      if (tick < interval) return;
      tick = 0;
      final result =
          await ref.read(syncControllerProvider.notifier).pollTrakt(code.deviceCode);
      if (!mounted) return;
      switch (result.state) {
        case TraktPollState.authorized:
          _done = true;
          timer.cancel();
          Navigator.of(context).pop(true);
        case TraktPollState.slowDown:
          interval += 1;
        case TraktPollState.expired:
          timer.cancel();
          setState(() => _error = '授权码已过期，请重试');
        case TraktPollState.denied:
          timer.cancel();
          setState(() => _error = '授权被拒绝');
        case TraktPollState.pending:
        case TraktPollState.error:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return AlertDialog(
      title: const Text('连接 Trakt'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else if (code == null)
              const Row(
                children: [
                  SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('正在获取授权码…'),
                ],
              )
            else ...[
              Text(_status),
              const SizedBox(height: 16),
              _CopyRow(label: '网址', value: code.verificationUrl),
              const SizedBox(height: 8),
              _CopyRow(label: '验证码', value: code.userCode, big: true),
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('等待授权…（${_remaining}s）',
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _pollTimer?.cancel();
            if (!_done) Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}

// ============ Bangumi 授权码登录对话框 ============

class _BangumiConnectDialog extends ConsumerStatefulWidget {
  const _BangumiConnectDialog();

  @override
  ConsumerState<_BangumiConnectDialog> createState() =>
      _BangumiConnectDialogState();
}

class _BangumiConnectDialogState extends ConsumerState<_BangumiConnectDialog> {
  final _codeController = TextEditingController();
  late final TextEditingController _redirectController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _redirectController = TextEditingController(
      text: ref.read(syncControllerProvider).bangumiRedirectUri,
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _redirectController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请先粘贴授权码');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final controller = ref.read(syncControllerProvider.notifier);
      await controller.setBangumiRedirectUri(_redirectController.text);
      await controller.connectBangumiWithCode(code);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '连接失败：$e';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = ref.read(syncControllerProvider.notifier).buildBangumiAuthorizeUrl();
    return AlertDialog(
      title: const Text('连接 Bangumi'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1. 在浏览器打开下方授权网址并登录授权：',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              _CopyRow(label: '授权网址', value: url),
              const SizedBox(height: 16),
              const Text('2. 授权后页面会显示一段授权码，粘贴到这里：',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: '授权码 (code)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('高级：回调地址',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                children: [
                  TextField(
                    controller: _redirectController,
                    decoration: const InputDecoration(
                      labelText: '回调地址（须与 Bangumi 后台一致）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('完成连接'),
        ),
      ],
    );
  }
}

/// 带「复制」按钮的只读信息行。
class _CopyRow extends StatelessWidget {
  final String label;
  final String value;
  final bool big;

  const _CopyRow({required this.label, required this.value, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: big ? 22 : 13,
                    fontWeight: big ? FontWeight.bold : FontWeight.normal,
                    letterSpacing: big ? 2 : 0,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              AppToast.show(context, '已复制');
            },
          ),
        ],
      ),
    );
  }
}
