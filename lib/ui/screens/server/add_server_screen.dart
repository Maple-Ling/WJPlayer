import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/server_providers.dart';
import '../../widgets/common/app_toast.dart';
import 'server_form_widget.dart';

/// 添加服务器页面（单表单）：名称(留空自动获取)/服务器备注/用户名/密码，
/// 连接并保存；下方 + 号可动态增删线路（线路备注/协议/地址/路径，默认路径 /）。
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({super.key, this.sourceKind = SourceKind.emby});

  /// 服务器源类型（emby / feiniu 等），决定保存时的鉴权走法。
  final SourceKind sourceKind;

  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends ConsumerState<AddServerScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加服务器')),
      body: ServerEditorForm(
        autoAddLine: true,
        sourceKind: widget.sourceKind,
        onSaved: (server) {
          if (!mounted) return;
          AppToast.show(context, '已连接并保存「${server.name}」',
              kind: AppToastKind.success);
          // 替换添加页为首页：返回时直接回到服务器管理页。
          context.pushReplacement('/home');
        },
      ),
    );
  }
}
