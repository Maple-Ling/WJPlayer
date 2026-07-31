import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/afdian_providers.dart';
import '../../../core/providers/calendar_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/afdian_service.dart';
import '../../../core/services/sync/calendar_models.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../core/utils/platform_utils.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/ranking_entry_panel.dart';

/// 打开追剧日历（未解锁先弹爱发电订单校验）。设置入口与底部导航共用。
Future<void> openCalendarGated(BuildContext context, WidgetRef ref) async {
  if (!ref.read(premiumUnlockedProvider)) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const AfdianUnlockDialog(),
    );
    if (ok != true || !context.mounted) return;
    AppToast.show(context, '已解锁追剧日历 ❤️');
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => const CalendarScreen()),
  );
}

/// 追剧日历（付费解锁，移动端 + 桌面端共用）。
///
/// 数据来源在 Trakt / Bangumi 间切换：Trakt 给精确放送日期，Bangumi 给每周放送日。
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late SyncService _source;
  bool _onlyMine = true;

  @override
  void initState() {
    super.initState();
    _source = calendarSourceOf(ref.read(calendarSourceProvider));
  }

  void _selectSource(SyncService s) {
    if (s == _source) return;
    setState(() => _source = s);
    ref.read(calendarSourceProvider.notifier).state = s.name;
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(syncControllerProvider).isConnected(_source);
    return Scaffold(
      appBar: AppBar(
        title: const Text('追剧日历'),
        actions: [
          TextButton.icon(
            icon: Icon(_onlyMine ? Icons.person : Icons.public, size: 18),
            label: Text(_onlyMine ? '只看我追的' : '整季全部'),
            onPressed: () => setState(() => _onlyMine = !_onlyMine),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => ref.invalidate(
                calendarEntriesProvider((source: _source, onlyMine: _onlyMine))),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<SyncService>(
              segments: const [
                ButtonSegment(
                  value: SyncService.trakt,
                  label: Text('Trakt'),
                  icon: Icon(Icons.movie_outlined),
                ),
                ButtonSegment(
                  value: SyncService.bangumi,
                  label: Text('Bangumi'),
                  icon: Icon(Icons.animation_outlined),
                ),
              ],
              selected: {_source},
              onSelectionChanged: (s) => _selectSource(s.first),
            ),
          ),
          Expanded(
            child: connected
                ? _CalendarList(source: _source, onlyMine: _onlyMine)
                : _NotConnected(source: _source),
          ),
        ],
      ),
    );
  }
}

class _NotConnected extends StatelessWidget {
  final SyncService source;
  const _NotConnected({required this.source});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('未连接 ${source.displayName}'),
          const SizedBox(height: 4),
          const Text('请先到「设置 → 同步服务」连接账号',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }
}

class _CalendarList extends ConsumerWidget {
  final SyncService source;
  final bool onlyMine;
  const _CalendarList({required this.source, required this.onlyMine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async =
        ref.watch(calendarEntriesProvider((source: source, onlyMine: onlyMine)));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '暂无放送数据。\nTrakt 需在追踪的剧集有排期；\nBangumi 仅显示「在看」中当季正在放送的番。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          );
        }
        final sections = groupCalendarEntries(entries);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          itemCount: sections.length,
          itemBuilder: (context, i) => _SectionView(section: sections[i]),
        );
      },
    );
  }
}

class _SectionView extends StatelessWidget {
  final CalendarSection section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Row(
            children: [
              Text(
                section.header,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: section.isToday ? accent : null,
                ),
              ),
              if (section.isToday) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('今天',
                      style: TextStyle(fontSize: 11, color: accent)),
                ),
              ],
            ],
          ),
        ),
        ...section.items.map((e) => _EntryTile(entry: e)),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  final CalendarEntry entry;
  const _EntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final img = entry.imageUrl;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => showCrossServerLookup(
          context,
          title: entry.title,
          imageUrl: img,
          subtitle: entry.subtitle,
          dialog: isDesktopPlatform,
        ),
        leading: img != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  img,
                  width: 40,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholder(),
                ),
              )
            : _placeholder(),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.subtitle != null ? Text(entry.subtitle!) : null,
        trailing: entry.airDate != null
            ? Text(
                '${entry.airDate!.hour.toString().padLeft(2, '0')}:'
                '${entry.airDate!.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              )
            : null,
      ),
    );
  }

  Widget _placeholder() => Container(
        width: 40,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(Icons.tv, size: 20, color: Colors.grey),
      );
}

/// 爱发电订单号解锁对话框（移动端 + 桌面端）。返回 true 表示解锁成功。
class AfdianUnlockDialog extends ConsumerStatefulWidget {
  const AfdianUnlockDialog({super.key});

  @override
  ConsumerState<AfdianUnlockDialog> createState() => _AfdianUnlockDialogState();
}

class _AfdianUnlockDialogState extends ConsumerState<AfdianUnlockDialog> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final orderNo = _controller.text.trim();
    if (orderNo.isEmpty) {
      setState(() => _error = '请输入订单号');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result =
        await ref.read(afdianServiceProvider).verifyOrder(orderNo);
    if (!mounted) return;
    if (result.valid) {
      ref.read(afdianOrderProvider.notifier).state = orderNo;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = result.reason ?? '校验未通过';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('解锁追剧日历'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '在爱发电赞助任意金额即可解锁追剧日历。赞助后到「我的 → 订单」'
                '复制订单号，粘贴到下方校验。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              const _CopyableUrl(url: kAfdianSponsorUrl),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: '订单号 (out_trade_no)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
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
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('校验并解锁'),
        ),
      ],
    );
  }
}

class _CopyableUrl extends StatelessWidget {
  final String url;
  const _CopyableUrl({required this.url});

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
          Expanded(child: SelectableText(url, style: const TextStyle(fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              AppToast.show(context, '已复制');
            },
          ),
        ],
      ),
    );
  }
}
