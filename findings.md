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
