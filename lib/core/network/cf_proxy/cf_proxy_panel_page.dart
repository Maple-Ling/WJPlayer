import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/server_providers.dart';
import 'cf_proxy_controller.dart';
import 'cf_speed_tester.dart';
import '../../../ui/widgets/common/app_toast.dart';

/// CF 优选反代可视化面板（PC 优先，移动/TV 也能用同一页面）。
///
/// 由插件经 `ctx.cfproxy.openPanel()` 打开。这里负责：选服务器 → 测速并反代
/// （带实时进度）→ 定时测速开关 → 自定义测速文件 → 一键关闭。
class CfProxyPanelPage extends ConsumerStatefulWidget {
  const CfProxyPanelPage({super.key});

  @override
  ConsumerState<CfProxyPanelPage> createState() => _CfProxyPanelPageState();
}

class _CfProxyPanelPageState extends ConsumerState<CfProxyPanelPage> {
  final CfProxyController _ctrl = CfProxyController.instance;
  final Map<String, CfTestProgress> _progress = {};
  final Map<String, CfCancelToken> _cancels = {};
  late final TextEditingController _globalUrlCtrl;

  @override
  void initState() {
    super.initState();
    // 移动/桌面端 main() 不会预初始化控制器（仅 TV 会），若未经 cf-proxy 插件启用流程
    // 注入过 container，speedTestAndApply 里 _server() 取不到服务器 → 抛「找不到服务器」。
    // 打开面板即幂等初始化，确保测速能读到服务器列表。
    _ctrl.ensureInit(ProviderScope.containerOf(context, listen: false));
    _globalUrlCtrl = TextEditingController(text: _ctrl.globalTestUrl);
    _ctrl.addListener(_onCtrl);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onCtrl);
    _globalUrlCtrl.dispose();
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  Future<void> _runTest(ServerConfig server) async {
    final cancel = CfCancelToken();
    _cancels[server.id] = cancel;
    setState(() {
      _progress[server.id] =
          const CfTestProgress(phase: CfTestPhase.sampling, message: '准备中…');
    });
    String? errMsg;
    try {
      final best = await _ctrl.speedTestAndApply(
        server.id,
        cancel: cancel,
        onProgress: (p) {
          if (p.phase == CfTestPhase.error && p.message != null) {
            errMsg = p.message;
          }
          if (mounted) setState(() => _progress[server.id] = p);
        },
      );
      if (!mounted) return;
      if (cancel.canceled) {
        AppToast.show(context, '已取消测速');
      } else if (best == null) {
        AppToast.show(context, errMsg ?? '测速失败：未找到可用的优选 IP',
            kind: AppToastKind.error);
      } else {
        AppToast.show(
            context,
            '已反代「${server.name}」→ ${best.ip}（${best.latencyMs}ms'
            '${best.downloadKBps != null ? ' · ${(best.downloadKBps! / 1024).toStringAsFixed(2)} MB/s' : ''}）');
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '测速出错: $e', kind: AppToastKind.error);
      }
    } finally {
      _cancels.remove(server.id);
      if (mounted) setState(() => _progress.remove(server.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('CF 优选反代')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildIntro(context),
          const SizedBox(height: 12),
          _buildIpMode(context),
          const SizedBox(height: 12),
          _buildGlobalTestUrl(context),
          const SizedBox(height: 16),
          if (servers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('还没有添加任何服务器')),
            )
          else
            for (final s in servers) _buildServerCard(context, s),
        ],
      ),
    );
  }

  Widget _buildIntro(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.bolt, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '为走 Cloudflare 的服务器，从本地实测挑出最快的 CF 边缘 IP，并通过本地'
                '反代改写线路。比公共优选 IP 更贴合你的网络。开启定时测速可全天候保速。',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIpMode(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Row(
          children: [
            const Icon(Icons.lan_outlined, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('优选协议',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            DropdownButton<CfIpMode>(
              value: _ctrl.ipMode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: CfIpMode.auto, child: Text('自动')),
                DropdownMenuItem(value: CfIpMode.v4, child: Text('仅 IPv4')),
                DropdownMenuItem(value: CfIpMode.v6, child: Text('仅 IPv6')),
                DropdownMenuItem(value: CfIpMode.dual, child: Text('双栈')),
              ],
              onChanged: (v) {
                if (v != null) _ctrl.setIpMode(v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalTestUrl(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('全局测速文件',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              '下载测速用的文件，需走 Cloudflare（支持自动跟随重定向）。默认为社区托管在'
              ' CF R2 上的 100MB 文件；也可换成你自己 R2 的测速文件，或公共测速链接'
              '（如 https://cf.xiu2.xyz/url）。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _globalUrlCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: kDefaultCfTestUrl,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    await _ctrl.setGlobalTestUrl(_globalUrlCtrl.text);
                    _globalUrlCtrl.text = _ctrl.globalTestUrl;
                    messenger?.showSnackBar(
                        const SnackBar(content: Text('已保存测速文件地址')));
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerCard(BuildContext context, ServerConfig server) {
    final theme = Theme.of(context);
    final state = _ctrl.stateFor(server.id);
    final active = _ctrl.isActive(server.id);
    final running = _progress.containsKey(server.id);
    final host = Uri.tryParse(server.directLineUrl)?.host ?? server.directLineUrl;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(server.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(host,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                _statusChip(theme, active),
              ],
            ),
            if (active && state?.pinnedIp != null) ...[
              const SizedBox(height: 8),
              _buildActiveInfo(theme, state!),
            ],
            if (running) ...[
              const SizedBox(height: 10),
              _buildProgress(theme, server.id),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (running)
                  OutlinedButton.icon(
                    onPressed: () => _cancels[server.id]?.cancel(),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('取消'),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => _runTest(server),
                    icon: const Icon(Icons.speed, size: 18),
                    label: Text(active ? '重新测速并反代' : '测速并反代'),
                  ),
                if (active && !running)
                  OutlinedButton.icon(
                    onPressed: () => _ctrl.disable(server.id),
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('关闭反代'),
                  ),
              ],
            ),
            const Divider(height: 24),
            _buildScheduleRow(context, server, state),
            _buildAdvanced(context, server, state),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(ThemeData theme, bool active) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        active ? '反代中' : '未启用',
        style: TextStyle(
          fontSize: 12,
          color: active
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildActiveInfo(ThemeData theme, CfServerState state) {
    final r = state.lastResult;
    final parts = <String>[
      '优选 IP ${state.pinnedIp}',
      if (r != null) '${r.latencyMs}ms',
      if (r?.downloadKBps != null)
        '${(r!.downloadKBps! / 1024).toStringAsFixed(2)} MB/s',
    ];
    return Text(
      parts.join(' · '),
      style: TextStyle(fontSize: 12.5, color: theme.colorScheme.primary),
    );
  }

  Widget _buildProgress(ThemeData theme, String serverId) {
    final p = _progress[serverId]!;
    final phaseLabel = switch (p.phase) {
      CfTestPhase.sampling => '抽样 IP',
      CfTestPhase.latency => '① 测延迟',
      CfTestPhase.validate => '② HTTP 校验',
      CfTestPhase.download => '③ 测速度',
      CfTestPhase.done => '完成',
      CfTestPhase.error => '出错',
    };
    // 把各阶段拼成一条**确定值**进度条，避免某阶段“转圈”让人以为卡住。
    // 抽样 0-3%，测延迟 3-45%，HTTP 校验 45-65%，测速度 65-100%。
    final sub = p.total > 0 ? (p.tested / p.total).clamp(0.0, 1.0) : 0.0;
    final double overall = switch (p.phase) {
      CfTestPhase.sampling => 0.03,
      CfTestPhase.latency => 0.03 + 0.42 * sub,
      CfTestPhase.validate => 0.45 + 0.20 * sub,
      CfTestPhase.download => 0.65 + 0.35 * sub,
      CfTestPhase.done => 1.0,
      CfTestPhase.error => 0.0,
    };
    final best = p.best;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(phaseLabel,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${(overall * 100).round()}%',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: overall, minHeight: 6),
        ),
        const SizedBox(height: 6),
        Text(
          p.message ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        if (best != null)
          Text(
            '当前最优 ${best.ip} · ${best.latencyMs}ms'
            '${best.downloadKBps != null ? ' · ${(best.downloadKBps! / 1024).toStringAsFixed(2)} MB/s' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
          ),
      ],
    );
  }

  Widget _buildScheduleRow(
      BuildContext context, ServerConfig server, CfServerState? state) {
    final enabled = state?.scheduleEnabled ?? false;
    final minutes = state?.scheduleMinutes ?? 30;
    return Row(
      children: [
        const Icon(Icons.schedule, size: 18),
        const SizedBox(width: 8),
        const Expanded(child: Text('定时测速', style: TextStyle(fontSize: 14))),
        if (enabled)
          DropdownButton<int>(
            value: const [15, 30, 60, 120, 360].contains(minutes) ? minutes : 30,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 15, child: Text('每 15 分')),
              DropdownMenuItem(value: 30, child: Text('每 30 分')),
              DropdownMenuItem(value: 60, child: Text('每 1 小时')),
              DropdownMenuItem(value: 120, child: Text('每 2 小时')),
              DropdownMenuItem(value: 360, child: Text('每 6 小时')),
            ],
            onChanged: (v) {
              if (v != null) _ctrl.setSchedule(server.id, true, v);
            },
          ),
        Switch(
          value: enabled,
          onChanged: (v) => _ctrl.setSchedule(server.id, v, minutes),
        ),
      ],
    );
  }

  Widget _buildAdvanced(
      BuildContext context, ServerConfig server, CfServerState? state) {
    final ctrl = TextEditingController(text: state?.testUrl ?? '');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text('高级（自定义测速文件）',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '留空=用全局测速文件',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await _ctrl.setServerTestUrl(server.id, ctrl.text);
                  messenger?.showSnackBar(
                      const SnackBar(content: Text('已保存')));
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
