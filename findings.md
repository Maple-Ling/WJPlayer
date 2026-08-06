# 重构分析发现

## 已完成
- 双击区域 1/4-1/2-1/4（player_screen_state.dart）
- HUD 位置 Center → Align(0, 0.333)（player_screen_state.dart）
- 长按倍速符号化显示 _formatSpeedSymbol（player_screen_state.dart）
- PlayerOverlay IgnorePointer 透传（player_overlay.dart）
- 比例精简 3 项（popup_menu_overlay.dart）
- _switchLine 立即重连播放器（player_screen_state.dart）
- TopBar 网速显示 1s 刷新（player_controls.dart + player_overlay.dart）
- 卡顿转圈中间显示网速（player_screen_state.dart）
- 手势拖动进度条位置修复（player_screen_state.dart）
- MPV 标签统一 → 原生 MPV（player_screen_state.dart + popup_menu_overlay.dart）
- 弹幕轨道高度 32→24 + 倍速同步基线修复（danmaku_overlay.dart）
- _ReorderableGrid 双排长按拖拽排序（server_list_screen.dart）
- 首页服务器选择器隐藏过滤（home_screen.dart）
- fnico.png → assets/icons/

## 待完成
- 飞牛图标渲染（用 fnico.png）
- 详情页浅蓝蒙版 + 分界线渐变
- 历史记录页进入自动刷新
- 服务器首页数据缓存
- 提交到 dev

## 2026-08-06 播放器问题修复启动
- 当前有效 Git 工作区为 `/var/minis/shared/WJPlayer-gitwork`，HEAD `f6a6fac`。
- `/var/minis/shared/WJPlayer` 是无 Git 副本；本轮按用户要求修改 gitwork。
- 已发现历史日志称亮度/音量快照已实现，但需核对当前 HEAD 是否完整、退出生命周期是否覆盖。
- 用户新增 5 项：亮度/音量退出恢复；聚合资源最多 3 个且复用详情资源框；媒体信息整体可翻页无胶囊；空白区域点击响应；选集固定 5 集可翻页。

## 2026-08-06 本轮根因定位
1. 亮度/音量快照目前挂在 `VideoPlayerService` 实例上；播放器切换内核/线路/资源时会 dispose 并新建 service，新实例把“播放中已调节的值”误当成页面进入值。退出时 `dispose()` 只是并发 `unawaited` 恢复，且没有屏幕级会话快照。
2. 新 `PlayerOverlay` 的聚合按钮在 `sources` 为空时只做条件判断、不执行任何回调，因此表现为失效；有资源时又被 `PopupMenuShell` 包裹，资源模型缺少详情资源卡的动态范围/编码/大小/码率字段。
3. 新覆盖层媒体信息仍是 `PopupMenuPill` 列表，一次性撑高，没有 PageView；选集也是所有 episode 的 Wrap，没有分页。
4. UI 可见时的空白点击层是透明 GestureDetector，但上层 Stack 命中关系不够明确；改为全屏 opaque tap target（控件在其上层），无视觉遮罩，空白点击统一隐藏/关闭菜单。
5. 当前有效入口是 `PlayerOverlay -> PopupMenuOverlay`，因此优先修该路径；旧胶囊/右侧面板保留作为兼容路径，避免删除已有功能。

## 收尾验证结果
- 4 个核心 Dart 文件：括号/方括号/大括号静态检查均通过。
- `git diff --check` 通过。
- 未下载 Dart/Flutter SDK，未执行本地构建；按用户要求留给 GitHub CI。
- 当前工作区修改集中在播放器系统控制、播放器状态接线、播放器覆盖层、弹层菜单及规划记录。

## 2026-08-06 进度拖动重构发现
- 根因1：BottomBar Slider 的 onChanged 与 onChangeEnd 都绑定同一个 seek 回调，拖动每帧并发发 seek，旧原生 position 回调覆盖新目标造成回弹。
- 根因2：VideoPlayerService.onDragEnd 先清 isScrubbingPosition 再异步 seek，UI 会瞬间读取旧 position。
- 根因3：屏幕水平手势预览未完整传入 PlayerOverlay/BottomBar；隐藏与显示 UI 使用不同状态源。
- 根因4：player_screen_state 旧 `_seekHint` 与 `_buildDragIndicator` 在屏幕中央显示相对时间，和新需求冲突。
- 当前方向：服务层 committed seek 稳定窗口；Slider 本地预览、松手单次 commit；目标绝对时间统一挂在进度条上方；旧中央提示彻底删除。
