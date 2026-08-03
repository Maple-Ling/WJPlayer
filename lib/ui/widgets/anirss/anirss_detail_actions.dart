import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../common/app_toast.dart';

/// 详情页订阅操作（三端共用逻辑）。触发 UI（菜单/按钮）由各端各自实现，
/// 这里统一动作执行 + 结果反馈 + provider 失效。
enum AniRssDetailAction { refreshCover, scrape, downloadPath, rate }

extension AniRssDetailActionMeta on AniRssDetailAction {
  String get label => switch (this) {
        AniRssDetailAction.refreshCover => '刷新封面',
        AniRssDetailAction.scrape => '重新刮削',
        AniRssDetailAction.downloadPath => '下载位置',
        AniRssDetailAction.rate => 'BGM 评分',
      };

  IconData get icon => switch (this) {
        AniRssDetailAction.refreshCover => Icons.image_outlined,
        AniRssDetailAction.scrape => Icons.auto_fix_high_outlined,
        AniRssDetailAction.downloadPath => Icons.folder_open_outlined,
        AniRssDetailAction.rate => Icons.star_outline_rounded,
      };
}

/// 执行某项详情操作。返回是否需要刷新详情（封面/刮削会改数据）。
Future<void> runAniRssDetailAction(
  BuildContext context,
  WidgetRef ref,
  AniRssApi api,
  AniModel ani,
  AniRssDetailAction action,
) async {
  switch (action) {
    case AniRssDetailAction.refreshCover:
      await _guard(context, '正在刷新封面…', () async {
        await api.refreshCover(ani);
        ref.invalidate(aniDetailProvider(ani));
        ref.invalidate(aniListProvider);
      }, ok: '封面已刷新');
      break;
    case AniRssDetailAction.scrape:
      await _guard(context, '正在重新刮削…', () async {
        await api.scrape(ani, force: true);
        ref.invalidate(aniDetailProvider(ani));
        ref.invalidate(aniListProvider);
      }, ok: '已触发重新刮削');
      break;
    case AniRssDetailAction.downloadPath:
      await _showDownloadPath(context, api, ani);
      break;
    case AniRssDetailAction.rate:
      await _showRateDialog(context, api, ani);
      break;
  }
}

Future<void> _guard(BuildContext context, String busy, Future<void> Function() run,
    {required String ok}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(busy)));
  try {
    await run();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(ok)));
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('失败：$e')));
  }
}

Future<void> _showDownloadPath(
    BuildContext context, AniRssApi api, AniModel ani) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _DownloadPathDialog(api: api, ani: ani),
  );
}

class _DownloadPathDialog extends StatefulWidget {
  final AniRssApi api;
  final AniModel ani;
  const _DownloadPathDialog({required this.api, required this.ani});

  @override
  State<_DownloadPathDialog> createState() => _DownloadPathDialogState();
}

class _DownloadPathDialogState extends State<_DownloadPathDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final d = await widget.api.downloadPath(widget.ani);
      if (mounted) {
        setState(() {
          _data = d;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('下载位置'),
      content: SizedBox(
        width: 420,
        child: _body(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const SizedBox(
          height: 80, child: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) return Text(_error!);
    if (_data.isEmpty) {
      return const Text('暂无下载位置信息', style: TextStyle(color: Colors.grey));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in _data.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.key,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                SelectableText('${e.value}',
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> _showRateDialog(
    BuildContext context, AniRssApi api, AniModel ani) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _RateDialog(api: api, ani: ani),
  );
}

class _RateDialog extends StatefulWidget {
  final AniRssApi api;
  final AniModel ani;
  const _RateDialog({required this.api, required this.ani});

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  int _rating = 0;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    try {
      final cur = await widget.api.rate(widget.ani);
      if (mounted) {
        setState(() {
          _rating = cur.clamp(0, 10);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_rating <= 0) return;
    setState(() => _submitting = true);
    try {
      // setRate 读 Ani.score 作为提交的评分。
      await widget.api
          .setRate(widget.ani.copyWithRaw({'score': _rating}));
      if (!mounted) return;
      Navigator.pop(context);
      AppToast.show(context, '已评分 $_rating 分');
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        AppToast.show(context, '评分失败：$e', kind: AppToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('BGM 评分 · ${widget.ani.title}'),
      content: _loading
          ? const SizedBox(
              height: 60, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    for (int i = 1; i <= 10; i++)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _rating = i),
                        icon: Icon(
                          i <= _rating
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: Colors.amber,
                        ),
                      ),
                  ],
                ),
                Text(_rating > 0 ? '$_rating / 10' : '未评分'),
              ],
            ),
      actions: [
        TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: (_submitting || _rating <= 0) ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('提交'),
        ),
      ],
    );
  }
}
