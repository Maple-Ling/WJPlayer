import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/tv_focus_manager.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/platform_utils.dart';
import '../../widgets/common/tv_focusable.dart';
import '../../widgets/common/tv_focus_widgets.dart';

/// 添加服务器第一步：可搜索的「源类型选择器」（移动端）。
///
/// 选 Emby → 进入现有 Emby 添加流程；选网盘类 → 进入该源登录页。
/// 列表由 [kSourceTypes] 驱动，后续接入新源会自动出现。
class SourcePickerScreen extends StatefulWidget {
  const SourcePickerScreen({super.key});

  @override
  State<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends State<SourcePickerScreen> {
  String _query = '';

  void _select(SourceKind kind) {
    // Emby / 飞牛统一走同一套添加表单，但通过参数区分源类型，保存时走对应鉴权。
    context.push('/add/emby?sourceKind=${kind.name}');
  }

  @override
  Widget build(BuildContext context) {
    final types = kSourceTypes
        .where((t) => t.kind == SourceKind.emby || t.kind == SourceKind.feiniu)
        .where((t) => t.matches(_query))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择要添加的服务')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索 Emby / Jellyfin / 飞牛影视',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: types.isEmpty
                ? const Center(child: Text('没有匹配的源类型'))
                : TvFocusArea(
                    // TV：初始聚焦第一个源类型，上下选择，OK 进入添加表单。
                    key: ValueKey('source_picker_${types.length}'),
                    id: 'source_picker',
                    count: types.length,
                    traversal: TraversalPolicies.linear(types.length),
                    child: Builder(
                      builder: (ctx) => ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: types.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final t = types[index];
                          return _SourceTypeCard(
                            descriptor: t,
                            // 手机端 TvFocusArea 不注册焦点区域，无条件
                            // getFocusNode 会抛 StateError → 整页灰屏。
                            focusNode: isTvPlatform
                                ? ctx.getFocusNode('source_picker', index)
                                : null,
                            onTap: () => _select(t.kind),
                          )
                              .animate()
                              .fadeIn(
                                delay: (index * 40).ms,
                                duration: AppMotion.medium,
                              )
                              .slideY(
                                  begin: 0.08,
                                  end: 0,
                                  curve: AppMotion.standard);
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceTypeCard extends StatelessWidget {
  final SourceTypeDescriptor descriptor;
  final VoidCallback onTap;

  /// TV 集中焦点管理注入的节点（null = 手机端，不接区域）。
  final FocusNode? focusNode;

  const _SourceTypeCard({
    required this.descriptor,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onActivate: onTap,
      borderRadius: 16,
      focusNode: focusNode,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: descriptor.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child:
                    Icon(descriptor.icon, color: descriptor.accent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      descriptor.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      descriptor.subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
