import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';

/// 服务器线路管理页面
class ServerLinesScreen extends ConsumerStatefulWidget {
  final String serverId;
  
  const ServerLinesScreen({super.key, required this.serverId});
  
  @override
  ConsumerState<ServerLinesScreen> createState() => _ServerLinesScreenState();
}

class _ServerLinesScreenState extends ConsumerState<ServerLinesScreen> {
  bool _isSyncing = false;

  Future<void> _syncLines() async {
    final servers = ref.read(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);

    if (server.authToken == null) {
      _showToast('服务器未登录，无法同步');
      return;
    }

    if (server.lines.isEmpty) {
      _showToast('当前没有可同步的线路');
      return;
    }

    setState(() {
      _isSyncing = true;
    });

    int totalAdded = 0;
    int syncSourceCount = 0;
    String? lastError;
    var workingServer = server;

    try {
      final service = ref.read(extDomainServiceProvider);

      // 尝试从每条现有线路同步
      for (final line in server.lines) {
        try {
          final lines = await service.fetchExtDomains(
            extDomainUrl: line.url,
            embyServerUrl: server.baseUrl,
            embyToken: server.authToken!,
          );

          if (lines.isNotEmpty) {
            syncSourceCount++;
            final newLines = lines
                .map(
                  (entry) => ServerLine(
                    id: '${DateTime.now().millisecondsSinceEpoch}_${entry.name}',
                    name: entry.name,
                    url: entry.url,
                    remark: entry.remark,
                  ),
                )
                .toList();

            // 合并现有线路和新线路（去重）
            final existingLines = workingServer.lines;
            final mergedLines = [...existingLines];
            for (final newLine in newLines) {
              if (!mergedLines.any((existing) => existing.url == newLine.url)) {
                mergedLines.add(newLine);
                totalAdded++;
              }
            }

            workingServer = workingServer.copyWith(lines: mergedLines);
            _persistServerUpdate(ref, workingServer);
          }
        } catch (e) {
          lastError = e.toString();
          // 继续尝试下一条线路
          continue;
        }
      }

      if (mounted) {
        if (totalAdded > 0) {
          _showToast('成功同步 $totalAdded 条线路（从 $syncSourceCount 个源）');
        } else if (syncSourceCount > 0) {
          _showToast('所有线路已是最新，没有新线路添加');
        } else {
          _showToast('同步失败：当前线路不支持自动同步${lastError != null ? '\n$lastError' : ''}');
        }
      }
    } catch (e) {
      if (mounted) {
        _showToast('同步失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  void _showToast(String message) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 56,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 2), () {
      overlayEntry.remove();
    });
  }
  
  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text('服务器线路'),
            Text(
              server.name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _addLine(context, ref),
            tooltip: '添加线路',
          ),
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _isSyncing ? null : _syncLines,
            tooltip: '同步线路',
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: server.lines.length,
        itemBuilder: (context, index) {
          final line = server.lines[index];
          final isActive = index == server.activeLineIndex;
          
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: isActive ? Theme.of(context).colorScheme.primaryContainer : null,
            child: ListTile(
              onTap: () {
                _persistServerUpdate(
                  ref,
                  server.copyWith(activeLineIndex: index),
                );
              },
              title: Text(line.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isActive ? '当前已启用线路' : '已配置线路'),
                  if (line.remark != null)
                    Text('备注：${line.remark}', style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isActive)
                    Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () => _editLine(context, ref, widget.serverId, line),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete, size: 20, color: Theme.of(context).colorScheme.error),
                    onPressed: () => _deleteLine(context, ref, widget.serverId, line),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
  
  void _addLine(BuildContext context, WidgetRef ref) {
    final serverId = widget.serverId;
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final remarkController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加线路'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '线路名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: remarkController,
              decoration: const InputDecoration(labelText: '备注'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              final newLine = ServerLine(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameController.text,
                url: urlController.text,
                remark: remarkController.text.isEmpty ? null : remarkController.text,
              );
              _persistServerUpdate(
                ref,
                server.copyWith(lines: [...server.lines, newLine]),
              );
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
  
  void _editLine(BuildContext context, WidgetRef ref, String serverId, ServerLine line) {
    final nameController = TextEditingController(text: line.name);
    final urlController = TextEditingController(text: line.url);
    final remarkController = TextEditingController(text: line.remark ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑线路'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '线路名称')),
            const SizedBox(height: 8),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: 'URL')),
            const SizedBox(height: 8),
            TextField(controller: remarkController, decoration: const InputDecoration(labelText: '备注')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              final updatedLines = server.lines.map((l) {
                if (l.id == line.id) {
                  return ServerLine(
                    id: l.id,
                    name: nameController.text,
                    url: urlController.text,
                    remark: remarkController.text.isEmpty ? null : remarkController.text,
                  );
                }
                return l;
              }).toList();
              _persistServerUpdate(
                ref,
                server.copyWith(lines: updatedLines),
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
  
  void _deleteLine(BuildContext context, WidgetRef ref, String serverId, ServerLine line) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除线路 "${line.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              final remainingLines =
                  server.lines.where((entry) => entry.id != line.id).toList();
              final nextActiveLineIndex = remainingLines.isEmpty
                  ? 0
                  : server.activeLineIndex.clamp(0, remainingLines.length - 1);
              _persistServerUpdate(
                ref,
                server.copyWith(
                  lines: remainingLines,
                  activeLineIndex: nextActiveLineIndex,
                ),
              );
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _persistServerUpdate(WidgetRef ref, ServerConfig updatedServer) {
    ref.read(serverListProvider.notifier).updateServer(updatedServer);
    final currentServer = ref.read(currentServerProvider);
    if (currentServer?.id == updatedServer.id) {
      ref.read(currentServerProvider.notifier).state = updatedServer;
    }
  }
}
