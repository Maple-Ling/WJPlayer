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
