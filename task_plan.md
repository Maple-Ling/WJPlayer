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

## TV 卡片聚焦放大裁切修复（进行中）
- [x] TvFocusable/TvFocusCard 放大溢出裁切：AnimatedScale 外包 Padding(4) 留白
- [x] PlaybackResourceCard 选中描边被 antiAlias 裁：Card clipBehavior→none + 内容 Padding(4)
- [x] 全部 TV 卡片网格/横滑列表 clipBehavior: Clip.none（10 文件）
- [x] 网格间距/外 padding/横滑区高度补偿放大溢出
- [x] Discover 海报卡底部年份加 Padding(bottom:4) 防描边遮挡
- [ ] CI 编译验证（本地无 dart 工具链，靠 GitHub CI）

## TV 方向键确定性导航（进行中）
- [x] FocusSection 加 trailing（行尾查看更多）；FocusSectionLayout 重写：左右逐卡片、下同列对齐、上两段式
- [x] appRouteObserver 全局路由观察器 + GoRouter observers 挂载
- [x] TvFocusable 支持 focusNode 注入；TvFocusArea 平台守卫 + 自动激活
- [x] 首页 TvFocusArea('home_media') 接入：继续观看行 + 库行 + 查看全部按钮；RouteAware 进出接管/恢复
- [x] _load 一次性加载全部预览（区域 count 稳定）
- [x] 模拟遍历 28 场景 PASS、括号平衡 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 状态栏菜单键进出与折叠联动（进行中）
- [x] TvFocusManager 新增 enterArea/exitArea/clearReturnTarget + _returnAreaId 来源记忆（删旧 toggleArea）
- [x] MENU 进入记录来源区域、退出归还来源焦点；无来源交还 Flutter 默认树
- [x] 上键退出状态栏（releaseOnUp）同样归还来源
- [x] 折叠状态 MENU 自动展开 + 切入焦点（_handleMenuKey）
- [x] 路由变化 clearReturnTarget（tab 切换后不回到不可见旧页面）
- [x] 模拟 7 场景 PASS、括号平衡 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 状态栏左右键直接切换页面（模块四 提示词 1）
- [x] FocusAreaConfig 新增 onMoveActivated（仅 moveDPad 触发，focusAt/switchArea 不触发）
- [x] main_tabs 注册 onMoveActivated → goBranch，左右键移动即切页
- [x] 边界核查：收缩模式不误切、goBranch 联动无循环
- [x] 模拟 PASS、括号 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 记录页焦点导航/多选删除/返回（模块四 提示词 2）
- [x] FocusAreaConfig 加 onLongPressAt/onBoundary + nextIndex 透传 -1 + moveDPad 边界处理
- [x] 状态栏 releaseOnUp 无来源→当前页面区域顶部；ignoreDown→当前页面区域第一卡（_currentPageAreaId）
- [x] TvKeyboardListener 长按 OK（enter/select repeat）→ onLongPressAt
- [x] MainShell _syncCurrentPageArea（/history → history）
- [x] 历史页 TvFocusArea：工具行+卡片遍历、长按多选、边界→状态栏、返回阶梯 PopScope
- [x] Builder 延迟取节点防 StateError；区域 Key 随记录数重建
- [x] 模拟 14 场景 PASS、括号 4 文件 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 服务器列表页顶部按钮/显隐/排序（模块四 提示词 3）
- [x] setCurrentPageArea 支持 topIndex/firstCardIndex（状态栏上→加号 3、下→第一卡 4）
- [x] MainShell _syncCurrentPageArea 加 '/servers' 映射
- [x] TvFocusArea('servers')：工具行(标题/布局/搜索/加号)+卡片；标题三连击 OK 显隐
- [x] 排序模式：长按 OK 进入、卡片抖动、方向键移动（单排上下/双排上下左右）、OK/返回退出
- [x] MENU 键 → 三点菜单（_MenuTile TV 可聚焦）；搜索模式不注册区域
- [x] 模拟 31 场景 PASS、括号 5 文件 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 服务器添加/编辑页表单焦点（模块四 提示词 4）
- [x] SourcePickerScreen：TvFocusArea 初始聚焦类型列表、上下选择、OK 进入
- [x] ServerEditorForm：TvFocusArea('server_form') 字段线性顺序（名称→备注→用户名→密码→TLS→加号→线路卡→保存）
- [x] 协议位左右直接切换 http/https（onBoundary + key 重建）
- [x] 线路卡内任意位置右键 → 删除按钮；多线路删除下→下一线路卡、最后→保存
- [x] ProtocolAddressField 加 focusNode 透传；按钮/TLS/保存 TvFocusable（自动滚动）
- [x] 模拟 38 场景 PASS、括号 8 文件 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 设置界面聚焦高亮与返回状态栏（模块四 提示词 5）
- [x] _SettingsCard 包 TvFocusable（聚焦描边+放大高亮）；_SettingsGroup Clip.none
- [x] TvFocusArea('settings') count=6 线性导航；关于下键/首卡上键 → 状态栏
- [x] PopScope 任意位置返回 → 状态栏；状态栏内返回 → 回影视 tab
- [x] MainShell _syncCurrentPageArea 加 '/settings'
- [x] 模拟 10 场景 PASS、括号 18 文件 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 任务栏搜索页焦点导航与聚合切换（模块四 提示词 6）
- [x] TvFocusArea('search')：0=搜索框、1=聚合开关；状态栏上/下 → 搜索框
- [x] 右键搜索框→聚合框，OK 切换聚合方式；聚合框上/左→搜索框
- [x] 选框下键/返回键 → 状态栏；状态栏内返回 → 回影视 tab
- [x] TextField TV 关闭 autofocus；_AggregateToggle 包 TvFocusable
- [x] MainShell _syncCurrentPageArea 加 '/search'
- [x] 模拟 17 场景 PASS、括号 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 全局输入框两段式 + 菜单/返回键权限（模块四 提示词 7）
- [x] TvInputField 组件：聚焦仅高亮描边、OK 进入编辑（IME）、手机零副作用
- [x] 表单 7 个 TextField + 搜索框全部两段式
- [x] MENU 返回状态栏仅限 /discover 与 /home（其他页 handled 吞掉）
- [x] 服务器页返回逻辑改造（排序退出/普通返回→状态栏/状态栏内返回→影视）
- [x] 模拟 25 场景 PASS、括号 20 文件 OK、git diff --check OK
- [ ] CI 编译验证（等用户推送后）

## 工作约束
- 不提交、不推送、不创建 tag，除非用户明确要求。
- 手机版必须零焦点副作用。
- 不在手机安装大型 SDK 或执行本地 Flutter 构建。

## 遇到的错误
| 错误 | 次数 | 处理 |
|---|---:|---|
| BusyBox grep 不支持 `--include` | 1 | 改用 `find ... -exec grep` |
| `rg` 未安装 | 1 | 使用 BusyBox find/grep，不安装工具 |

## 当前专项：TV 版全面问题审计（2026-08-10）
目标：基于当前 `dev`/`8892f0b` 代码，找出实际影响 TV 聚焦、交互逻辑、播放卡顿/PPT 的根因，区分已修复、仍存在、待实机验证的问题；只分析，不改业务代码、不提交、不推送。

### 阶段
- [ ] 建立版本/构建/平台边界与变更基线
- [ ] 审计焦点系统、路由、菜单、返回、输入、详情/播放器
- [ ] 审计播放链路、解码选择、ASS/字幕、渲染与状态更新
- [ ] 用静态证据和场景矩阵判定实际影响及优先级
- [ ] 输出问题清单、根因、验证证据与修复优先级

### 约束
- 不安装 Flutter/Dart/大型检测工具，不执行本地构建。
- 不提交、不推送、不创建 tag。
- 关键发现写入 `findings.md`，阶段进度写入 `progress.md`。
| `app_router.dart` 导入粘连 | 1 | 纳入本轮修复 |
