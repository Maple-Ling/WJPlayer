import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../widgets/common/app_toast.dart';
import 'server_form_widget.dart';

/// 编辑服务器页面：名称/备注/地址/路径/用户名/密码 + 完整线路编辑（点编辑即进入所有线路编辑）。
class EditServerScreen extends ConsumerStatefulWidget {
  final String serverId;

  const EditServerScreen({super.key, required this.serverId});

  @override
  ConsumerState<EditServerScreen> createState() => _EditServerScreenState();
}

class _EditServerScreenState extends ConsumerState<EditServerScreen> {
  ServerConfig? _server;

  @override
  void initState() {
    super.initState();
    final servers = ref.read(serverListProvider);
    ServerConfig? found;
    for (final s in servers) {
      if (s.id == widget.serverId) {
        found = s;
        break;
      }
    }
    _server = found;
    if (found == null) {
      // 服务器可能已被删除，返回。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑服务器')),
      body: server == null
          ? const SizedBox.shrink()
          : ServerEditorForm(
              existing: server,
              allowInsecureTls: server.allowInsecureTls,
              hideMainUrl: true,
              onSaved: (updated) {
                if (!mounted) return;
                AppToast.show(context, '服务器已更新');
                context.pop();
              },
            ),
    );
  }
}
