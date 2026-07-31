part of 'settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      // 底部预留浮动 TabBar 的高度（MainShell 已把它注入 MediaQuery.padding.bottom）。
      // ListView 显式设置 padding 会忽略 MediaQuery 内边距，故需手动叠加，
      // 否则最后一张卡片会被底部 Tab 挡住。
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _SettingsCard(
            icon: Icons.dns,
            title: 'Emby 服务器',
            subtitle: '添加、编辑、切换服务器',
            onTap: () => _showServers(context),
          ),
          _SettingsCard(
            icon: Icons.palette,
            title: '通用设置',
            subtitle: '外观、语言、启动页等',
            onTap: () => _showGeneralSettings(context),
          ),
          _SettingsCard(
            icon: Icons.play_circle,
            title: '播放器设置',
            subtitle: '内核、手势、播放行为等',
            onTap: () => _showPlayerSettings(context),
          ),
          _SettingsCard(
            icon: Icons.chat_bubble,
            title: '弹幕设置',
            subtitle: '外观、屏蔽词、延迟等',
            onTap: () => _showDanmakuSettings(context),
          ),
          _SettingsCard(
            icon: Icons.translate,
            title: '字幕翻译',
            subtitle: 'AI / 百度 / 腾讯翻译，Whisper 本地转写',
            onTap: () => _showTranslationSettings(context),
          ),
          // 移动端只保留 CF 优选加速；通用代理(HTTP/SOCKS)仅 TV/PC 需要，移动端不再展示
          //（移动端系统级代理软件已很完善，不需要 App 自带）。
          _SettingsCard(
            icon: Icons.bolt,
            title: 'CF 优选加速',
            subtitle: '实测最快 Cloudflare 边缘 IP 并本地反代提速',
            onTap: () => _showCfProxy(context),
          ),
          if (isDesktopPlatform)
            _SettingsCard(
              icon: Icons.vpn_key,
              title: '代理设置',
              subtitle: 'HTTP/SOCKS 自定义代理，可仅代理请求不代理播放',
              onTap: () => _showNetworkSettings(context),
            ),
          _SettingsCard(
            icon: Icons.sync_alt,
            title: '同步记录',
            subtitle: '跨服务器续播，联动本地观看记录',
            onTap: () => _showResumeSync(context),
          ),
          _SettingsCard(
            icon: Icons.layers,
            title: '跨服聚合',
            subtitle: '选择哪些服务器参与详情页「其他服务器版本」聚合',
            onTap: () => _showAggregation(context),
          ),
          _SettingsCard(
            icon: Icons.sync,
            title: '同步服务',
            subtitle: 'Trakt、Bangumi 观看记录同步',
            onTap: () => _showSyncSettings(context),
          ),
          _SettingsCard(
            icon: Icons.calendar_month,
            title: '追剧日历',
            subtitle: ref.watch(premiumUnlockedProvider)
                ? '已解锁 · Trakt / Bangumi 放送日程'
                : '赞助解锁 · 追踪 Trakt / Bangumi 放送日程',
            onTap: () => _openCalendar(context, ref),
          ),
          _SettingsCard(
            icon: Icons.extension,
            title: '插件',
            subtitle: '安装、启用/禁用第三方插件',
            onTap: () => _showPlugins(context),
          ),
          _SettingsCard(
            icon: Icons.system_update,
            title: '检查更新',
            subtitle: '当前 $kCurrentAppVersion · 每 24 小时自动检查',
            onTap: () => _checkUpdate(context, ref),
          ),
          _SettingsCard(
            icon: Icons.alt_route,
            title: '更新渠道',
            subtitle: updateChannelLabel(ref.watch(updateChannelProvider)),
            onTap: () => _pickUpdateChannel(context, ref),
          ),
          _SettingsCard(
            icon: Icons.info,
            title: '关于',
            subtitle: '版本、开源许可、致谢',
            onTap: () => _showAbout(context),
          ),
          _SettingsCard(
            icon: Icons.backup,
            title: '备份与恢复',
            subtitle: '导出/导入服务器配置、WebDAV同步',
            onTap: () => _showBackupRestore(context),
          ),
          _SettingsCard(
            icon: Icons.qr_code_2,
            title: '配置迁移',
            subtitle: '扫码在设备间搬服务器配置（含登录凭据）',
            onTap: () => _showConfigMigration(context),
          ),
          // 线路同步已移至各服务器的线路管理页面
        ],
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

  void _showCfProxy(BuildContext context) =>
      _openSubPage(context, const CfProxyPanelPage());

  // 通用代理设置仅桌面端入口（移动端交给系统代理软件）。
  void _showNetworkSettings(BuildContext context) =>
      _openSubPage(context, const NetworkSettingsScreen());

  void _showResumeSync(BuildContext context) =>
      _openSubPage(context, const ResumeSyncScreen());

  void _showAggregation(BuildContext context) =>
      _openSubPage(context, const AggregationSettingsScreen());

  void _showSyncSettings(BuildContext context) =>
      _openSubPage(context, const SyncSettingsScreen());

  /// 追剧日历入口：未解锁先弹爱发电订单校验，解锁后进日历页。
  void _openCalendar(BuildContext context, WidgetRef ref) =>
      openCalendarGated(context, ref);

  void _showTranslationSettings(BuildContext context) =>
      _openSubPage(context, const TranslationSettingsScreen());

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WJPlayer v$kCurrentAppVersion'),
            SizedBox(height: 8),
            Text('GitHub: https://github.com/your-repo'),
            SizedBox(height: 8),
            Text('mpv version: 0.37.0'),
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

  void _showConfigMigration(BuildContext context) =>
      _openSubPage(context, const ConfigMigrationScreen());

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
    final channel = ref.read(updateChannelProvider);
    final UpdateInfo? info;
    try {
      info = await ref.read(appUpdateServiceProvider).checkForUpdate(
            includePrerelease: channel == UpdateChannel.prerelease,
          );
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(context, '检查更新失败，请稍后重试',
          kind: AppToastKind.error);
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

/// 设置卡片
class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFF5B8DEF)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// 通用设置页
