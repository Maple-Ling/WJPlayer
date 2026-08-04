# 重构进度日志

## 2026-08-04
- 启动22项重构任务，基线 654946a
- 提交 97b75db: 顶栏网速 + MPV比例/自适应 + 首页缓存优化雏形

## 2026-08-05
- 完成剩余 5 项收口：历史页进入自动刷新、详情页浅蓝蒙版移除、详情页播放键渐变联动、
  首页服务器持久化缓存(HomeDataCache/HomeCacheLoader)、聚合搜索复用 PlaybackResourceCard。
- MediaItem/Library 增 fromJson/toJson；PersistentJsonCache 增 delete。
- 静态检查：9 个改动文件括号/括弧全部平衡，符号引用一致。
- 本地无法编译（x86_64 Flutter 缺 qemu ld-linux）。
