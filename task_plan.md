# WJPlayer 剩余修改任务计划

## 当前基线
- 本地 HEAD: 97b75db (dev)
- 远端 origin/dev: 8580146

## 本轮完成
- [x] 播放记录页进入自动刷新 (history_screen initState/didChangeDependencies + app_router 路由监听)
- [x] 详情页浅蓝蒙版移除 (color_extractor gradientStart 改用背景色)
- [x] 详情页播放键分界线与渐变联动 (_PlaybackHeaderDelegate 随滚动渐隐)
- [x] 所有服务器首页本地持久化缓存 (HomeDataCache + HomeCacheLoader, 服务器隔离, 24h)
- [x] 聚合搜索复用 PlaybackResourceCard, 移除独立卡片实现
- [x] MediaItem/Library 补 fromJson/toJson 供缓存序列化

## 待用户确认
- 提交本地 + 是否推送 dev / 触发 CI（按用户指令）

## 环境说明
- 本地 Flutter 为 x86_64，缺 qemu ld-linux，无法本地编译；仅做静态括号/符号一致性检查。
