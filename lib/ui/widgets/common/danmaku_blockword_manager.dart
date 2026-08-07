import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/playback_providers.dart';
import '../../../core/utils/danmaku_filter.dart';
import 'app_toast.dart';

/// 弹幕屏蔽词管理面板（播放器弹幕菜单与设置页共用）。
///
/// 支持添加单个屏蔽词、从弹弹play XML 导入（文本词 + 用户ID 屏蔽）。
class DanmakuBlockwordManagerSheet extends ConsumerStatefulWidget {
  const DanmakuBlockwordManagerSheet({super.key});

  @override
  ConsumerState<DanmakuBlockwordManagerSheet> createState() =>
      _DanmakuBlockwordManagerSheetState();
}

class _DanmakuBlockwordManagerSheetState
    extends ConsumerState<DanmakuBlockwordManagerSheet> {
  void _showAddDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加屏蔽词'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入屏蔽词...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final word = controller.text.trim();
              if (word.isNotEmpty) {
                ref.read(danmakuBlockwordsProvider.notifier).addWord(word);
              }
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入弹弹弹幕屏蔽词'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('支持导入弹弹play导出的 XML 格式屏蔽词文件。'),
            SizedBox(height: 8),
            Text(
              '会自动识别文本屏蔽词和用户ID屏蔽。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              Navigator.pop(context);
              await _pickAndImportXml();
            },
            label: const Text('选择 XML 文件'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndImportXml() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xml'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      final path = file.path;

      String xmlContent;
      if (bytes != null) {
        xmlContent = utf8.decode(bytes);
      } else if (path != null) {
        xmlContent = await File(path).readAsString();
      } else {
        throw Exception('无法读取文件内容');
      }

      final importResult = DanmakuFilter.importFromDandanplayXml(xmlContent);

      ref
          .read(danmakuBlockwordsProvider.notifier)
          .importWords(importResult.textWords);
      ref
          .read(danmakuBlockwordsProvider.notifier)
          .importUserBlocks(importResult.userIds);

      if (context.mounted) {
        AppToast.show(
          context,
          '已导入 ${importResult.totalImported} 个屏蔽词'
          '${importResult.skippedCount > 0 ? '（跳过 ${importResult.skippedCount} 个）' : ''}',
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.show(context, '导入失败: $e', kind: AppToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text(
                      '屏蔽词管理',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.add),
                      onSelected: (value) {
                        if (value == 'add') {
                          _showAddDialog();
                        } else if (value == 'import') {
                          _showImportDialog();
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'add',
                          child: Row(
                            children: [
                              Icon(Icons.edit),
                              SizedBox(width: 8),
                              Text('添加屏蔽词'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'import',
                          child: Row(
                            children: [
                              Icon(Icons.download),
                              SizedBox(width: 8),
                              Text('导入弹弹弹幕屏蔽词'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: Consumer(
                    builder: (context, ref, child) {
                      final words = ref.watch(danmakuBlockwordsProvider);
                      if (words.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.block,
                                size: 48,
                                color:
                                    Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '暂无屏蔽词',
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: words.length,
                        itemBuilder: (context, index) {
                          final word = words[index];
                          return ListTile(
                            title: Text(word),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () {
                                ref
                                    .read(danmakuBlockwordsProvider.notifier)
                                    .removeWord(word);
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 弹出一个屏蔽词管理底部面板。
Future<void> showDanmakuBlockwordManager(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const DanmakuBlockwordManagerSheet(),
  );
}
