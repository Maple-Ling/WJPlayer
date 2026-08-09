part of 'settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// TV 设置卡片数（固定 7 张：界面/播放/弹幕/检查更新/备份与恢复/配置同步/关于）。
  static const int _cardCount = 7;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // TV：设置页注册焦点区域（卡片线性导航，方向键边界 → 状态栏）；
    // 返回键放行系统默认（逐级后退/分支根返回回影视 tab，主流 TV 语义）。
    final tvAreaReady = isTvPlatform;
    return PopScope(
      canPop: true, // 不拦截返回：手机/电视一致走系统返回。
      child: tvAreaReady
          ? TvFocusArea(
              id: 'settings',
              count: _cardCount,
              // 单列线性：顶部上键/底部「关于」下键 → 状态栏（onBoundary）。
              traversal: (current, direction) {
                switch (direction) {
                  case DPad.up:
                    return current > 0 ? current - 1 : -1;
                  case DPad.down:
                    return current < _cardCount - 1 ? current + 1 : -1;
                  case DPad.left:
                  case DPad.right:
                    return current;
                }
              },
              onBoundary: (_) =>
                  TvFocusManager.instance.enterArea('main_tabs'),
              // Builder 保证取焦点节点时区域已注册。
              child: Builder(
                builder: (ctx) => _buildList(ctx, ref),
              ),
            )
          : _buildList(context, ref),
    );
  }

  Widget _buildList(BuildContext ctx, WidgetRef ref) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final useTv = isTvPlatform &&
        TvFocusManager.instance.getArea('settings') != null;
    FocusNode? node(int i) => useTv ? ctx.getFocusNode('settings', i) : null;
    return Scaffold(
      backgroundColor:
          isDark ? AppColors.darkBackground : AppColors.lightBackground,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            24 + MediaQuery.of(ctx).padding.bottom,
          ),
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 24),
              child: Text(
                '设置',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  height: 1.05,
                ),
              ),
            ),
            _SettingsGroup(children: [
              _SettingsCard(focusNode: node(0), icon: Icons.dashboard_customize_rounded, title: '界面', subtitle: '布局、语言与启动页', onTap: () => _showGeneralSettings(ctx)),
              _SettingsCard(focusNode: node(1), icon: Icons.play_circle_fill_rounded, title: '播放', subtitle: '内核、手势与播放行为', onTap: () => _showPlayerSettings(ctx)),
              _SettingsCard(focusNode: node(2), icon: Icons.chat_bubble_rounded, title: '弹幕', subtitle: '外观、屏蔽词与延迟', onTap: () => _showDanmakuSettings(ctx), showDivider: false),
            ]),
            _SettingsGroup(children: [
              _SettingsCard(focusNode: node(3), icon: Icons.system_update_rounded, title: '检查更新', subtitle: '当前 $kCurrentAppVersion · 每 24 小时自动检查', onTap: () => _checkUpdate(ctx, ref), showDivider: false),
              _SettingsCard(focusNode: node(4), icon: Icons.restore_page_rounded, title: '备份与恢复', subtitle: '备份或恢复设置', onTap: () => _showBackupRestore(ctx)),
            ]),
            _SettingsGroup(children: [
              // TV：接收二维码（手机扫码推送）；手机：扫码同步到电视。
              _SettingsCard(focusNode: node(5), icon: Icons.sync_rounded, title: '配置同步', subtitle: '局域网传输服务器与弹幕配置', onTap: () => _showConfigSync(ctx), showDivider: false),
            ]),
            _SettingsGroup(children: [
              _SettingsCard(focusNode: node(6), icon: Icons.info_rounded, title: '关于', subtitle: '版本、开源许可与致谢', onTap: () => _showAbout(ctx), showDivider: false),
            ]),
          ],
        ),
      ),
    );
  }

  // 子页一律 push 到根导航器：原先落在 GoRouter 的 shell 分支导航器上，Android
  // 系统返回手势经 GoRouter 分发时不识别分支内的命令式路由 → 整个 app 被弹回桌面
  //（只有 AppBar 的 Navigator.pop 有效）。落到根导航器后返回手势/返回键都能正确
  // 回退一级。子页内再 push（如播放器→交互）会自动落到根导航器，无需单独处理。
  void _openSubPage(BuildContext context, Widget page) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  void _showGeneralSettings(BuildContext context) =>
      _openSubPage(context, const GeneralSettingsScreen());

  void _showPlayerSettings(BuildContext context) =>
      _openSubPage(context, const PlayerSettingsScreen());

  void _showDanmakuSettings(BuildContext context) =>
      _openSubPage(context, const DanmakuSettingsScreen());

  // 通用代理设置仅桌面端入口（移动端交给系统代理软件）。
  void _showNetworkSettings(BuildContext context) =>
      _openSubPage(context, const NetworkSettingsScreen());

  void _showAggregation(BuildContext context) =>
      _openSubPage(context, const AggregationSettingsScreen());

  void _showSyncSettings(BuildContext context) =>
      _openSubPage(context, const SyncSettingsScreen());

  void _showTranslationSettings(BuildContext context) =>
      _openSubPage(context, const TranslationSettingsScreen());

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WJPlayer v$kCurrentAppVersion'),
            const SizedBox(height: 8),
            InkWell(
              onTap: () =>
                  launchUrl(Uri.parse('https://github.com/Maple-Ling/WJPlayer'),
                      mode: LaunchMode.externalApplication),
              borderRadius: BorderRadius.circular(6),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new_rounded, size: 15),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'GitHub: https://github.com/Maple-Ling/WJPlayer',
                      style: TextStyle(
                          color: Color(0xFF5B8DEF),
                          decoration: TextDecoration.underline,
                          decorationColor: Color(0xFF5B8DEF)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text('mpv version: 0.37.0'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _exportLogs(context);
            },
            child: const Text('导出日志'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final path = await AppLogger().exportToFile();
      final livePath = AppLogger().logFilePath;
      await Clipboard.setData(ClipboardData(text: path));
      if (context.mounted) {
        AppToast.show(
          context,
          '日志已导出（路径已复制）:\n$path'
          '${livePath != null ? '\n实时日志文件: $livePath' : ''}',
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.show(context, '导出日志失败: $e', kind: AppToastKind.error);
      }
    }
  }

  void _showBackupRestore(BuildContext context) =>
      _openSubPage(context, const BackupRestoreScreen());

  /// 配置同步：TV 接收二维码（手机扫码推送）；手机扫码同步到电视。
  void _showConfigSync(BuildContext context) => _openSubPage(
        context,
        isTvPlatform
            ? const ConfigSyncReceiverScreen()
            : const ConfigSyncSenderScreen(),
      );

  void _showPlugins(BuildContext context) =>
      _openSubPage(context, const PluginManagementScreen());

  void _showServers(BuildContext context) =>
      _openSubPage(context, const ServerListScreen());

  Future<void> _pickUpdateChannel(BuildContext context, WidgetRef ref) async {
    final current = ref.read(updateChannelProvider);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新渠道'),
        content: RadioGroup<UpdateChannel>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(updateChannelProvider.notifier).state = value;
            }
            Navigator.pop(ctx);
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<UpdateChannel>(
                title: Text('稳定版（latest）'),
                subtitle: Text('只接收正式发布，最稳定'),
                value: UpdateChannel.stable,
              ),
              RadioListTile<UpdateChannel>(
                title: Text('预览版（pre-release）'),
                subtitle: Text('尝鲜，含预发布版本，可能有不稳定'),
                value: UpdateChannel.prerelease,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    AppToast.show(context, '正在检查更新…');
    final UpdateInfo? info;
    try {
      info = await ref.read(appUpdateServiceProvider).checkForUpdate(
            includePrerelease: false,
          );
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(context, '检查更新失败，请稍后重试', kind: AppToastKind.error);
      return;
    }
    if (!context.mounted) return;
    if (info == null) {
      AppToast.show(context, '已是最新版本（$kCurrentAppVersion）');
    } else {
      ref.read(availableUpdateProvider.notifier).state = info;
      await showUpdateDialog(context, info);
    }
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      // Clip.none：TV 聚焦放大（TvFocusable 1.04）不被圆角容器裁切。
      clipBehavior: Clip.none,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(children: children),
    );
  }
}

/// 设置卡片
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
    this.focusNode,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  /// TV 集中焦点管理注入的节点（null = 手机端，不接区域）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const iconColors = [
      Color(0xFFFF9500),
      Color(0xFF34C759),
      Color(0xFF007AFF),
      Color(0xFFFF2D55),
      Color(0xFFAF52DE),
    ];
    final iconColor = iconColors[title.hashCode.abs() % iconColors.length];
    return TvFocusable(
      // TV：聚焦时显示主题色描边 + 轻微放大（清晰可见的高亮标识）。
      onActivate: onTap,
      borderRadius: 22,
      focusNode: focusNode,
      child: Column(
        children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.white, size: 25),
            ),
            title:
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                  color:
                      isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: isDark ? const Color(0xFFB8B8BA) : const Color(0xFF8E8E93),
            ),
            onTap: onTap,
          ),
          if (showDivider)
            Divider(
              height: 1,
              indent: 80,
              endIndent: 16,
              color: isDark ? AppColors.darkDivider : AppColors.lightDivider,
            ),
        ],
      ),
    );
  }
}

/// 通用设置页
