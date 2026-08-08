# WJPlayer 剩余修改任务计划

## 当前基线
- 本地 HEAD: 8c92e34 (release-1.0.1)
- 当前任务：统一 Flutter Android TV 按键、路由与焦点控制系统

## TV 焦点重构（进行中）
- [x] MainActivity 仅拦截 MENU/专用硬键，D-pad/确认/返回保留 Flutter 原生链路
- [x] 抽离原生 MethodChannel 服务 `tv_key_channel.dart`
- [x] 新增集中式 `TvFocusManager` 与遍历策略
- [x] 将 app_router 底部 Tab 焦点迁移到集中管理器，路由进出主页时 switchArea/releaseArea
- [x] 修复当前增量代码中的导入、生命周期、事件分发和焦点抢占问题
- [x] 将现有 `TvFocusable` 媒体卡接入统一管理，保留 Flutter 自动几何遍历与滚动能力（默认 autofocus=false + TvKeyboardListener 回退 next/left/right）
- [x] 补齐路由切换后的初始焦点和 MENU 返回底栏恢复行为（lastFocusIndex 记忆）
- [x] 完成 Kotlin/Dart 轻量静态检查与 diff 审查（dart_lex_check 7 文件全 OK、git diff --check 通过）

## 工作约束
- 不提交、不推送、不创建 tag，除非用户明确要求。
- 手机版必须零焦点副作用。
- 不在手机安装大型 SDK 或执行本地 Flutter 构建。

## 遇到的错误
| 错误 | 次数 | 处理 |
|---|---:|---|
| BusyBox grep 不支持 `--include` | 1 | 改用 `find ... -exec grep` |
| `rg` 未安装 | 1 | 使用 BusyBox find/grep，不安装工具 |
| `app_router.dart` 导入粘连 | 1 | 纳入本轮修复 |
