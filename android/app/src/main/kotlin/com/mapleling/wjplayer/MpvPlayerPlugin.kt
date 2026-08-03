package com.mapleling.wjplayer

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import `is`.xyz.mpv.MPVLib
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Flutter platform channel plugin for native mpv playback.
 *
 * Follows the same MethodChannel + EventChannel pattern as ExoPlayerPlugin.
 * Each player instance wraps an MPVLib-managed mpv context. The video surface
 * from Flutter's TextureRegistry is attached to mpv via MPVLib.attachSurface(),
 * which sets the "wid" option — mpv creates its own EGL context on the surface
 * and manages all rendering internally.
 */
class MpvPlayerPlugin(
    private val context: Context,
    private val binaryMessenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "MpvPlayerPlugin"
        // fontconfig 设置结果（system 字体源是否存在/CJK 是否在），随 FILE_LOADED 的
        // sub-diag 一并转发进 App 日志，便于远程判定"字幕不显示"是否卡在字体源。
        @JvmStatic
        var lastFontStatus: String = "(未初始化)"
        private const val METHOD_CHANNEL = "com.mapleling.wjplayer/mpv"
    }

    private val players = ConcurrentHashMap<String, MpvPlayerInstance>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.d(TAG, "onMethodCall: ${call.method}, players=${players.keys}")
        when (call.method) {
            "createPlayer" -> {
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Number>("startPositionMs")?.toInt() ?: 0
                val dolbyVisionFix = call.argument<Boolean>("dolbyVisionFix") ?: false
                val preferredSubtitleLanguage = call.argument<String>("preferredSubtitleLanguage")
                val hardwareDecoding = call.argument<Boolean>("hardwareDecoding") ?: true
                // Dart 传过来的 int 在 Android 端可能是 Long，用 Number 兼容
                val surfaceViewId = call.argument<Number>("surfaceViewId")?.toInt()
                val useGpuNext = call.argument<Boolean>("useGpuNext") ?: false
                // 用户自定义代理（仅 HTTP 代理可被 mpv 消费；为空则直连）
                val httpProxy = call.argument<String>("httpProxy")
                // 统一 UA：部分 CDN 拒绝 mpv 默认 UA 导致取流失败。
                val userAgent = call.argument<String>("userAgent")
                // 逐流 HTTP 头（网盘/聚合源直链需 Cookie/Authorization/Referer）。
                val httpHeaders = call.argument<Map<String, String>>("httpHeaders")
                // 网络播放磁盘缓存（按用户 300MB–8GB 设置；本地文件为空/0 表示不启用）
                val videoCacheDir = call.argument<String>("videoCacheDir")
                val diskCacheForwardBytes = call.argument<Number>("diskCacheForwardBytes")?.toLong() ?: 0L
                val diskCacheBackBytes = call.argument<Number>("diskCacheBackBytes")?.toLong() ?: 0L
                createPlayer(videoUrl, startPositionMs, hardwareDecoding, surfaceViewId, useGpuNext, httpProxy, userAgent, httpHeaders, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result)
            }
            "reloadPlayer" -> {
                // L2 原地重载：外层重解析重签后的新 URL，复用同一 surface/texture，免黑屏。
                val playerId = call.argument<String>("playerId") ?: ""
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Number>("startPositionMs")?.toInt() ?: 0
                getPlayer(playerId)?.reload(videoUrl, startPositionMs)
                result.success(true)
            }
            "play" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.play()
                result.success(true)
            }
            "pause" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.pause()
                result.success(true)
            }
            "seekTo" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val positionMs = call.argument<Number>("positionMs")?.toInt() ?: 0
                getPlayer(playerId)?.seekTo(positionMs)
                result.success(true)
            }
            "setSpeed" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val speed = call.argument<Double>("speed") ?: 1.0
                getPlayer(playerId)?.setSpeed(speed)
                result.success(true)
            }
            "setVolume" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val volume = call.argument<Double>("volume") ?: 1.0
                getPlayer(playerId)?.setVolume(volume)
                result.success(true)
            }
            "getPosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val pos = getPlayer(playerId)?.getPosition() ?: 0
                result.success(pos)
            }
            "getDuration" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val dur = getPlayer(playerId)?.getDuration() ?: 0
                result.success(dur)
            }
            "getVideoSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = getPlayer(playerId)?.getVideoSize()
                result.success(size ?: mapOf("width" to 0, "height" to 0))
            }
            "getTracks" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val tracks = getPlayer(playerId)?.getTracksInfo()
                result.success(tracks ?: emptyList<Map<String, Any>>())
            }
            "selectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectSubtitleTrack(trackId)
                result.success(true)
            }
            "deselectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.deselectSubtitleTrack()
                result.success(true)
            }
            "selectAudioTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectAudioTrack(trackId)
                result.success(true)
            }
            "loadSubtitle" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val subtitleUrl = call.argument<String>("subtitleUrl") ?: ""
                val subtitleLanguage = call.argument<String>("subtitleLanguage") ?: "und"
                getPlayer(playerId)?.loadSubtitle(subtitleUrl, subtitleLanguage)
                result.success(true)
            }
            "setProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = call.argument<String>("value") ?: ""
                getPlayer(playerId)?.setProperty(name, value)
                result.success(true)
            }
            "getProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getProperty(name)
                result.success(value)
            }
            "getPropertyDouble" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getPropertyDouble(name)
                result.success(value)
            }
            "command" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                @Suppress("UNCHECKED_CAST")
                val args = call.argument<List<String>>("args") ?: emptyList()
                getPlayer(playerId)?.command(args.toTypedArray())
                result.success(true)
            }
            "screenshot" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val bitmap = getPlayer(playerId)?.screenshot()
                result.success(bitmap)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("sub-delay", seconds.toString())
                result.success(true)
            }
            "setAudioDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("audio-delay", seconds.toString())
                result.success(true)
            }
            "setSubtitleFont" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val fontName = call.argument<String>("fontName") ?: ""
                getPlayer(playerId)?.setProperty("sub-font", fontName)
                result.success(true)
            }
            "setSubtitleSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = call.argument<Double>("size") ?: 0.5
                // Keep the media-provided font size/style. Only disable window-dependent scaling.
                getPlayer(playerId)?.setProperty("sub-scale-by-window", "no")
                getPlayer(playerId)?.setProperty("sub-scale-with-window", "no")
                getPlayer(playerId)?.setProperty("sub-ass-scale-with-window", "no")
                getPlayer(playerId)?.setProperty("sub-use-margins", "yes")
                getPlayer(playerId)?.setProperty("sub-ass-force-margins", "yes")
                result.success(true)
            }
            "setSubtitlePosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val position = call.argument<Double>("position") ?: 0.0
                // mpv sub-pos: 0=top, 100=bottom (inverted from UI)
                // 固定在画面底部，避免字幕随画面比例/裁切模式漂移。
                getPlayer(playerId)?.setProperty("sub-pos", "100")
                result.success(true)
            }
            "setSubtitleBackground" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: false
                getPlayer(playerId)?.setProperty(
                    "sub-back-color",
                    if (enabled) "0.0/0.0/0.0/0.75" else "0.0/0.0/0.0/0.0"
                )
                result.success(true)
            }
            "setAspectRatio" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val ratio = call.argument<String>("ratio") ?: "自动"
                getPlayer(playerId)?.setAspectRatio(ratio)
                result.success(true)
            }
            "disposePlayer" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                disposePlayer(playerId)
                result.success(true)
            }
            "getCacheDir" -> {
                result.success(context.cacheDir.absolutePath)
            }
            "writeFile" -> {
                val path = call.argument<String>("path") ?: ""
                val data = call.argument<ByteArray>("data")
                if (path.isNotEmpty() && data != null) {
                    try {
                        java.io.File(path).writeBytes(data)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WRITE_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGS", "path and data required", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 移动端内封文本字幕 SRT/ASS 不显示的**真正根因**（grep -a libmpv.so 二进制核实，
     * 推翻了之前"走 fontconfig"的想当然）：
     *   - 这颗 libmpv(v0.36.0-549) 的 libass **没编 fontconfig**——FcInit/FcFontMatch/
     *     FcConfigParse 等符号全为 0；
     *   - mpv 的 `sub-font` / `sub-fonts-dir` / `sub-font-provider` 选项**在这颗 .so 里不存在**
     *     （字符串全为 0），setOptionString 到它们是静默 no-op；
     *   - libass 只剩 **"目录 provider"** 一条路：mpv 用 `ass_set_fonts_dir(config-dir/fonts)`
     *     扫字体目录，并把 `config-dir/subfont.ttf` 当**默认字体**（SRT/无样式 ASS 的 sans-serif
     *     最终落到这个默认字体）。
     * 之前生成 fonts.conf + 设 FONTCONFIG_FILE **完全空转**（没有 fontconfig 引擎去读它）→
     * libass 零可用字体 → 文本字幕整段不渲染；PGS 位图不吃字体，故一直正常。
     *
     * 修法：把 /system/fonts 里的字体**软链**进 `config-dir/fonts`（具名 ASS 字体可解析），
     * 并挑一个含 CJK 的字体软链成 `config-dir/subfont.ttf`（无样式 SRT/中文默认字体）。软链
     * 不拷贝、零额外包体；个别机型私有目录禁软链时退回硬拷贝兜底。config-dir 与 setMpvOptions
     * 里的 `config-dir=<filesDir>/mpv` 必须一致，否则 libass 扫不到。内封子集化特效 ASS 的附件
     * 字体仍由 libass(embeddedfonts=yes)从容器直接加载，不受此目录影响。
     */
    private fun setupLibassFonts(context: android.content.Context) {
        try {
            // 与 setMpvOptions 的 config-dir 保持一致：<filesDir>/mpv。
            val mpvDir = File(context.filesDir, "mpv")
            val fontsDir = File(mpvDir, "fonts")
            fontsDir.mkdirs()

            val sysDir = File("/system/fonts")
            val sysFiles = sysDir.listFiles { f ->
                val n = f.name.lowercase()
                n.endsWith(".ttf") || n.endsWith(".ttc") || n.endsWith(".otf")
            } ?: emptyArray()

            // 把系统字体逐个软链进 config-dir/fonts（幂等：已存在跳过）。
            var linked = 0
            for (src in sysFiles) {
                val link = File(fontsDir, src.name)
                if (link.exists()) { linked++; continue }
                try {
                    android.system.Os.symlink(src.absolutePath, link.absolutePath)
                    linked++
                } catch (_: Throwable) {
                    try { src.copyTo(link, overwrite = false); linked++ } catch (_: Throwable) {}
                }
            }

            // 默认字体：优先含 CJK 的字体，保证纯中文 SRT/无样式 ASS 有字可显。
            val cjkFont = sysFiles.firstOrNull {
                val n = it.name
                n.contains("NotoSansCJK", true) || n.contains("NotoSansSC", true) ||
                    n.contains("NotoSerifCJK", true) || n.contains("DroidSansFallback", true)
            } ?: sysFiles.firstOrNull { it.name.contains("Roboto-Regular", true) }
              ?: sysFiles.firstOrNull()

            val defaultFont = File(mpvDir, "subfont.ttf")
            var defaultName = "none"
            if (defaultFont.exists()) {
                defaultName = "exists"
            } else if (cjkFont != null) {
                try {
                    android.system.Os.symlink(cjkFont.absolutePath, defaultFont.absolutePath)
                    defaultName = cjkFont.name
                } catch (_: Throwable) {
                    try {
                        cjkFont.copyTo(defaultFont, overwrite = false); defaultName = cjkFont.name
                    } catch (_: Throwable) {}
                }
            }

            // 版本无关第二条腿：给**带 fontconfig 的 libmpv(0.41+)**生成 fonts.conf 并用
            // FONTCONFIG_FILE 指过去。0.36 无 fontconfig(上面目录 provider 生效)、0.41 有
            // fontconfig(读这份 conf)——两套 .so 都能显示文本字幕，升级不回归。必须在
            // MPVLib.create() 之前设 env(fontconfig 初始化即读环境变量)，本函数正是在其之前调用。
            var fcStatus = "off"
            try {
                val fcDir = File(mpvDir, "fontconfig")
                val fcCache = File(fcDir, "cache"); fcCache.mkdirs()
                val confFile = File(fcDir, "fonts.conf")
                confFile.writeText(
                    """<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/system/fonts</dir>
  <dir>/product/fonts</dir>
  <dir>${fontsDir.absolutePath}</dir>
  <cachedir>${fcCache.absolutePath}</cachedir>
  <alias><family>sans-serif</family><prefer><family>Noto Sans CJK SC</family><family>Noto Sans</family><family>Roboto</family><family>Droid Sans Fallback</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Noto Serif CJK SC</family><family>Noto Serif</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Droid Sans Mono</family><family>Roboto Mono</family></prefer></alias>
</fontconfig>
"""
                )
                android.system.Os.setenv("FONTCONFIG_FILE", confFile.absolutePath, true)
                android.system.Os.setenv("FONTCONFIG_PATH", fcDir.absolutePath, true)
                fcStatus = "conf=${confFile.exists()}"
            } catch (e: Throwable) {
                fcStatus = "fail:${e.message}"
            }

            lastFontStatus = "libass-fonts dir=${fontsDir.absolutePath}(${linked}/${sysFiles.size}链) " +
                "default=$defaultName sys=${sysDir.exists()} fontconfig=$fcStatus"
            android.util.Log.i(TAG, "libass fonts ready: $lastFontStatus")
        } catch (e: Exception) {
            lastFontStatus = "libass-fonts setup FAILED: ${e.message}"
            android.util.Log.e(TAG, "setupLibassFonts failed", e)
        }
    }

    private fun createPlayer(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        surfaceViewId: Int?,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        httpHeaders: Map<String, String>?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        // Always use SurfaceTexture (no SurfaceView polling needed)
        mainHandler.post { createPlayerOnMainThread(videoUrl, startPositionMs, hardwareDecoding, useGpuNext, httpProxy, userAgent, httpHeaders, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result) }
    }

    private fun createPlayerOnMainThread(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        httpHeaders: Map<String, String>?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
        try {
            // MPVLib is a singleton — only one mpv context can exist at a time.
            // Dispose any existing player first.（放进 try：release 内部异常也不外泄）
            if (players.isNotEmpty()) {
                android.util.Log.w(TAG, "createPlayer: disposing existing player(s)")
                players.values.forEach { it.release() }
                players.clear()
            }

            val playerId = UUID.randomUUID().toString()

            // Always use SurfaceTexture for both gpu and gpu-next modes
            surfaceTextureEntry = textureRegistry.createSurfaceTexture()
            val surfaceTexture = surfaceTextureEntry.surfaceTexture()

            // Set initial surface size using screen dimensions (landscape orientation)
            // IMPORTANT: Must be set BEFORE creating Surface to avoid SurfaceSyncer errors
            val dm = context.resources.displayMetrics
            val screenW = if (dm.widthPixels > dm.heightPixels) dm.widthPixels else dm.heightPixels
            val screenH = if (dm.widthPixels > dm.heightPixels) dm.heightPixels else dm.widthPixels
            surfaceTexture.setDefaultBufferSize(screenW, screenH)

            val surface = Surface(surfaceTexture)

            // Create mpv context.
            // 这一步会触发 MPVLib 的 init{}（首次访问时 System.loadLibrary("mpv"/"player")），
            // 从而把 libmpv.so 及其依赖 libavcodec.so 真正加载进进程。
            // 必须在 create/loadfile 之前把字体软链进 config-dir/fonts + subfont.ttf，
            // 否则 libass(无 fontconfig)零字体、文本字幕不渲染。见 setupLibassFonts 注释。
            setupLibassFonts(context)
            MPVLib.create(context)

            // 注册 JavaVM 给 ffmpeg（av_jni_set_java_vm，mediacodec 硬解必需）。
            // 必须放在 MPVLib.create() 之后：nativeRegisterJavaVm 通过 dlsym 取
            // av_jni_set_java_vm 符号，而该符号来自 libavcodec.so——首帧播放时若在
            // libmpv 加载前调用，dlsym 返回 null、原生侧调用空指针 → SIGSEGV 闪退。
            // 崩溃会重启进程，使每次播放又成"首帧" → 表现为"每次播放必闪退"。
            MpvInitBridge.ensureJavaVmRegistered()

            // Set mpv options (must be before init)
            android.util.Log.i(TAG, "Setting mpv options: hardwareDecoding=$hardwareDecoding, useGpuNext=$useGpuNext")
            setMpvOptions(hardwareDecoding, useGpuNext = useGpuNext, httpProxy = httpProxy,
                userAgent = userAgent,
                httpHeaders = httpHeaders,
                videoCacheDir = videoCacheDir,
                diskCacheForwardBytes = diskCacheForwardBytes,
                diskCacheBackBytes = diskCacheBackBytes)

            // Initialize mpv (registers JavaVM, starts event thread)
            MPVLib.init()

            MPVLib.attachSurface(surface)

            // Notify mpv of initial render target dimensions
            MPVLib.setPropertyString("android-surface-size", "${screenW}x${screenH}")

            // Enable video output
            MPVLib.setPropertyBoolean("force-window", true)

            // Set up EventChannel
            val eventChannel = EventChannel(
                binaryMessenger,
                "$METHOD_CHANNEL/events/$playerId"
            )

            val mpvTexture = MpvTexture(surfaceTextureEntry)
            val instance = MpvPlayerInstance(
                playerId = playerId,
                context = context,
                surface = surface,
                mpvTexture = mpvTexture,
                eventChannel = eventChannel,
                mainHandler = mainHandler
            )

            // Register observer（含日志订阅：把 mpv 原生 warn/error/fatal 落到 App 日志）
            MPVLib.addObserver(instance)
            MPVLib.addLogObserver(instance)

            // Observe key properties
            MPVLib.observeProperty("time-pos", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("duration", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("pause", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("paused-for-cache", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("eof-reached", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("idle-active", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("speed", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("volume", MPVLib.MpvFormat.DOUBLE)
            // track-list 用 NONE 格式观察：mpv 每次轨道变化都会回调 eventProperty(name)，
            // 由其触发 loadTracks() 重新解析并推送 tracksChanged。原来用 NODE 格式，但
            // eventProperty 没有任何重载消费 NODE → 轨道变化从不二次上报，只在 FILE_LOADED
            // 推一次（且可能在 Dart 订阅前丢失）。字幕轨常在 FILE_LOADED 后才完全就绪，
            // NONE 观察保证 Dart 侧 _tracks 最终一定拿到完整内封字幕/音轨列表。
            MPVLib.observeProperty("track-list", MPVLib.MpvFormat.NONE)
            MPVLib.observeProperty("video-params/w", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("video-params/h", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("hwdec-current", MPVLib.MpvFormat.STRING)
            // 诊断：观察当前应显示的字幕文本，上升沿写日志（见 eventProperty String 分支）。
            MPVLib.observeProperty("sub-text", MPVLib.MpvFormat.STRING)

            players[playerId] = instance

            // Load the video
            if (videoUrl.isNotEmpty()) {
                // 续播：在 loadfile 之前通过 start 属性指定起始位置，让 mpv 在加载时
                // 直接定位到续播点。旧做法是 loadfile 之后立刻发 seek，但 loadfile 是
                // 异步的，文件尚未解封装完成时 seek 会落空被丢弃，导致"时不时从头播放"。
                // 用 start 选项可彻底消除该竞态，且不会出现先闪一下片头的问题。
                if (startPositionMs > 0) {
                    MPVLib.setPropertyString("start", "${startPositionMs / 1000.0}")
                    android.util.Log.i(TAG, "Resume playback from ${startPositionMs / 1000.0}s")
                } else {
                    MPVLib.setPropertyString("start", "none")
                }
                MPVLib.command(arrayOf("loadfile", videoUrl, "replace"))
                val voMode = if (useGpuNext) "gpu-next" else "gpu"
                android.util.Log.i(TAG, "Loading video, SurfaceTexture/$voMode")
            } else {
                android.util.Log.w(TAG, "videoUrl is empty, not loading")
            }

            // Return result with texture info
            val resultMap = mutableMapOf<String, Any>(
                "playerId" to playerId,
                "textureId" to surfaceTextureEntry.id()
            )
            android.util.Log.i(TAG, "Created player with SurfaceTexture (textureId=${surfaceTextureEntry.id()})")
            result.success(resultMap)
        } catch (e: Throwable) {
            // 关键：必须捕获 Throwable 而非 Exception。
            // MPVLib / MpvInitBridge 首次访问会触发 object 的 init{} 静态初始化里的
            // System.loadLibrary()，.so 缺失/加载失败抛的是 UnsatisfiedLinkError /
            // ExceptionInInitializerError —— 它们继承 Error 而非 Exception，会绕过
            // catch(Exception) 直接在主线程未捕获 → 整个 App 崩溃(日志表现为 CRASH(JVM)、
            // 既无"初始化完成"也无"初始化失败")。捕获 Throwable 后降级为可恢复的错误，
            // 播放页按统一文案提示，并把真实原因抛回 Dart 落入日志。
            android.util.Log.e(TAG, "createPlayer failed", e)
            try { MPVLib.destroy() } catch (_: Throwable) {}
            try { surfaceTextureEntry?.release() } catch (_: Throwable) {}
            try { players.clear() } catch (_: Throwable) {}
            // 带上原生库加载失败详情（若有），让 Dart 日志直接看到"哪个 .so、为何加载失败"，
            // 而不是只看到下游的 "MPVLib.create 无实现"。
            val libInfo = MPVLib.loadErrors.let { if (it.isEmpty()) "" else " nativeLibLoad=[$it]" }
            result.error(
                "CREATE_ERROR",
                "${e.javaClass.simpleName}: ${e.message}$libInfo",
                null
            )
        }
    }

    /**
     * 检测设备是否支持杜比视界显示
     */
    private fun isDolbyVisionSupported(): Boolean {
        return try {
            val activity = context as? android.app.Activity ?: return false
            val display = activity.display ?: return false
            val hdrCapabilities = display.hdrCapabilities ?: return false
            val supportedHdrTypes = hdrCapabilities.supportedHdrTypes
            // Display.HdrCapabilities.DOLBY_VISION = 2
            supportedHdrTypes.contains(2)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "检测杜比视界支持失败: ${e.message}")
            false
        }
    }

    private fun setMpvOptions(
        hardwareDecoding: Boolean,
        useGpuNext: Boolean = false,
        httpProxy: String? = null,
        userAgent: String? = null,
        httpHeaders: Map<String, String>? = null,
        videoCacheDir: String? = null,
        diskCacheForwardBytes: Long = 0L,
        diskCacheBackBytes: Long = 0L,
    ) {
        // 用户自定义 HTTP 代理（mpv 不支持 SOCKS，SOCKS 场景在 TV 上经 mihomo 本地口中转）
        if (!httpProxy.isNullOrEmpty()) {
            MPVLib.setOptionString("http-proxy", httpProxy)
            android.util.Log.i(TAG, "mpv http-proxy enabled")
        }

        // 统一 UA：部分 CDN 拒绝 mpv/libavformat 默认 UA 导致取流失败（403/空响应）。
        if (!userAgent.isNullOrEmpty()) {
            MPVLib.setOptionString("user-agent", userAgent)
            android.util.Log.i(TAG, "mpv user-agent set: $userAgent")
        }

        // 逐流 HTTP 头（网盘/聚合源直链需 Cookie/Authorization/Referer）。
        // mpv 用 http-header-fields（逗号分隔的 "Key: Value"，不含 User-Agent）。
        if (!httpHeaders.isNullOrEmpty()) {
            val fields = httpHeaders.entries
                .filter { it.key.lowercase() != "user-agent" }
                .joinToString(",") { "${it.key}: ${it.value}" }
            if (fields.isNotEmpty()) {
                MPVLib.setOptionString("http-header-fields", fields)
                android.util.Log.i(TAG, "mpv http-header-fields set (${httpHeaders.size} headers)")
            }
        }

        // Video output - try gpu-next for better HDR/DV support, fallback to gpu if unavailable
        var actuallyUsingGpuNext = false
        if (useGpuNext) {
            try {
                MPVLib.setOptionString("vo", "gpu-next")
                actuallyUsingGpuNext = true
                android.util.Log.i(TAG, "Configured mpv for gpu-next rendering")
            } catch (e: Exception) {
                // gpu-next not available (requires Vulkan/libplacebo), fallback to gpu
                android.util.Log.w(TAG, "gpu-next not available, falling back to gpu: ${e.message}")
                MPVLib.setOptionString("vo", "gpu")
                android.util.Log.i(TAG, "Configured mpv for gpu rendering (fallback)")
            }
        } else {
            MPVLib.setOptionString("vo", "gpu")
            android.util.Log.i(TAG, "Configured mpv for gpu rendering")
        }

        // Common GPU settings
        MPVLib.setOptionString("gpu-context", "android")
        MPVLib.setOptionString("opengl-es", "yes")

        // HDR/杜比视界设置
        MPVLib.setOptionString("target-colorspace-hint", "yes")

        if (actuallyUsingGpuNext) {
            // gpu-next 模式：libplacebo 处理 DV RPU 元数据，正确映射 IPT-PQ 色空间
            MPVLib.setOptionString("dolby-vision-mode", "auto")
            MPVLib.setOptionString("tone-mapping", "spline")
            // hdr-compute-peak 是逐帧 GPU 直方图（compute shader），在移动 GPU 上开销很大。
            // 软解时 CPU 已被解码吃满，再叠加 per-frame 峰值检测会让画面明显卡顿，故软解路径
            // 关闭、改用静态元数据；硬解有 GPU 余量时保留以求更准的动态色调映射。
            MPVLib.setOptionString("hdr-compute-peak", "no")
            android.util.Log.i(TAG, "DV: gpu-next mode, static HDR peak for smooth playback")
        } else {
            // gpu 模式：不处理 DV RPU，用 video filter 去除 DV 标记避免绿屏
            MPVLib.setOptionString("vf", "format:dolbyvision=no")
            android.util.Log.i(TAG, "DV: gpu mode, stripping DV metadata via vf filter")
        }

        // Hardware decoding
        if (hardwareDecoding) {
            // 零拷贝直连硬解（性能关键）：改回 direct `mediacodec`，不再用 copy 模式。
            // 依据(decode-diag 实测 + 二进制核实)：copy 模式把每帧 GPU→CPU→GPU 拷贝一遍，
            // 1080p 尚可(实测 0 丢帧)，但 4K/高码率(86Mbps/64G)电影下这份逐帧拷贝撑爆内存
            // 带宽 → 严重卡顿；别的 MPV 播放器用的正是 direct(零拷贝) 故不卡。这颗 .so 有
            // AImage_getHardwareBuffer/AImageReader 全套符号，direct + vo=gpu 走 AHardwareBuffer
            // → EGLImage → GL 纹理的零拷贝导入，字幕/OSD 仍由 mpv 在 GL 层合成，不受影响。
            // 当年切走 copy 是因"首帧 SIGSEGV"，但那更可能是 av_jni_set_java_vm 时序问题——现已
            // 在 create() 之后显式注册 JavaVM（见 ensureJavaVmRegistered），根因已消除。解码失败
            // 时 mpv 仍自动回退软解。
            MPVLib.setOptionString("hwdec", "mediacodec")
            MPVLib.setOptionString("hwdec-codecs",
                "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        } else {
            MPVLib.setOptionString("hwdec", "no")
            // 软解性能优化：4K HEVC/杜比视界纯软解极吃 CPU，默认配置下移动端会严重卡顿。
            // ① 解码线程铺满 CPU 核心——mpv 的 auto 在部分机型只用了一半核，显式给满。
            val decodeThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 16)
            MPVLib.setOptionString("vd-lavc-threads", decodeThreads.toString())
            // ② 跳过非参考帧的环路去块滤波 + 启用快速(非严格合规)解码路径：省下可观 CPU，
            //    肉眼几乎无损，是软解能否跑到实时帧率的关键。
            MPVLib.setOptionString("vd-lavc-skiploopfilter", "nonref")
            MPVLib.setOptionString("vd-lavc-fast", "yes")
            // ③ 解码器直接渲染，省一次帧拷贝。
            MPVLib.setOptionString("vd-lavc-dr", "yes")
            // ④ 仍跟不上实时时允许在 VO 丢帧追平，避免音画不同步与持续卡顿堆积。
            MPVLib.setOptionString("framedrop", "vo")
            android.util.Log.i(TAG, "Software decode tuned: threads=$decodeThreads, skiploopfilter=nonref, fast=yes")
        }

        // 安全加固 · CVE-2026-8461 (PixelSmash)：libavcodec 的 magicyuv 解码器存在可被恶意
        // 视频触发的堆越界。升级到 0.41 后 libavcodec 仍含该解码器,软解路径可被触发。与桌面
        // (mpv_player_adapter 已设 vd=-magicyuv)对齐,在 Android 侧一并拉黑该解码器。
        MPVLib.setOptionString("vd", "-magicyuv")

        // 音画同步与倍速：对齐飞牛参考客户端。较小 AudioTrack 缓冲可降低倍速调整延迟，
        // audio 主时钟 + pitch correction 避免非 1x 时频繁 underrun/追帧抖动。
        MPVLib.setOptionString("hr-seek", "yes")
        MPVLib.setOptionString("force-seekable", "yes")
        MPVLib.setOptionString("audio-buffer", "0.15")
        MPVLib.setOptionString("video-latency-hacks", "yes")
        MPVLib.setOptionString("video-sync", "audio")
        MPVLib.setOptionString("video-sync-max-video-change", "5")
        MPVLib.setOptionString("video-sync-max-audio-change", "0.125")
        MPVLib.setOptionString("audio-pitch-correction", "yes")

        // Android 多数设备只暴露双声道 AudioTrack。先向 FFmpeg 解码器请求 stereo
        // downmix（TrueHD/EAC3/DTS-HD 能原生降混时最稳），不支持的编码再由 mpv 的
        // swresample 标准矩阵兜底；旧版强制 ad-lavc-downmix=no 在部分 7.1/DV 文件上
        // 会得到设备不接受的多声道 PCM，最终表现为整段无声。
        MPVLib.setOptionString("ao", "audiotrack,opensles")
        MPVLib.setOptionString("audio-channels", "stereo")
        MPVLib.setOptionString("ad-lavc-downmix", "yes")
        MPVLib.setOptionString("audio-normalize-downmix", "yes")
        MPVLib.setOptionString("audio-format", "s16")
        MPVLib.setOptionString("audio-samplerate", "48000")

        // Config
        MPVLib.setOptionString("config", "yes")
        val configDir = File(context.filesDir, "mpv")
        configDir.mkdirs()
        MPVLib.setOptionString("config-dir", configDir.absolutePath)

        // Idle and window management
        MPVLib.setOptionString("idle", "once")
        MPVLib.setOptionString("force-window", "no")

        // Subtitles
        MPVLib.setOptionString("sub-visibility", "yes")
        // 字幕走 OSD 覆盖层渲染，不混入视频帧。blend-subtitles=video 会让
        // PGS/SUP 位图字幕每次刷新都重绘整帧，造成视频画面闪现。
        MPVLib.setOptionString("blend-subtitles", "no")
        MPVLib.setOptionString("sub-auto", "all")
        MPVLib.setOptionString("sub-ass", "yes")
        MPVLib.setOptionString("sub-scale-by-window", "no")
        MPVLib.setOptionString("sub-scale-with-window", "no")
        MPVLib.setOptionString("sub-ass-scale-with-window", "no")
        MPVLib.setOptionString("sub-use-margins", "yes")
        MPVLib.setOptionString("sub-ass-force-margins", "yes")
        // 显式保住内封子集化特效 ASS 的**附件字体**：libass 直接用容器里嵌的字体，
        // 不经 fontconfig、不被系统字体替换 → 特效字幕按作者字体渲染，不会"被干到别的字体"。
        MPVLib.setOptionString("embeddedfonts", "yes")
        MPVLib.setOptionString("sub-codepage", "utf-8")
        // 字体来源不走选项：这颗 .so 无 fontconfig、也无 sub-fonts-dir 选项（二进制核实，
        // 见 setupLibassFonts）。libass 走目录 provider，字体已在 setupLibassFonts 里软链进
        // config-dir/fonts + config-dir/subfont.ttf，此处无需再设任何字体选项。

        // Cache
        // 网络播放：缓冲落磁盘（内部存储,快），避免大缓冲占满内存导致低配机/TV OOM。
        // 注：磁盘缓存**不是**大码率卡顿的瓶颈——实测缓存目录在内部存储(getApplicationCache-
        // Directory=/data/user/0/...，非 FUSE)，写入 100MB/s+ 绰绰有余。真瓶颈是 302 跳转流的
        // 分段请求开销(见 stream-lavf-o)。videoCacheDir 为空（本地文件）时退回小额内存缓冲。
        if (!videoCacheDir.isNullOrEmpty() && diskCacheForwardBytes > 0L) {
            File(videoCacheDir).mkdirs()
            MPVLib.setOptionString("cache", "yes")
            MPVLib.setOptionString("cache-pause", "yes")
            MPVLib.setOptionString("cache-pause-wait", "2.5")
            MPVLib.setOptionString("cache-pause-initial", "no")
            MPVLib.setOptionString("demuxer-seekable-cache", "yes")
            MPVLib.setOptionString("demuxer-cache-wait", "no")
            MPVLib.setOptionString("stream-buffer-size", "33554432")
            MPVLib.setOptionString("cache-on-disk", "yes")
            MPVLib.setOptionString("cache-dir", videoCacheDir)
            MPVLib.setOptionString("demuxer-max-bytes", diskCacheForwardBytes.toString())
            MPVLib.setOptionString("demuxer-max-back-bytes", diskCacheBackBytes.toString())
            MPVLib.setOptionString("demuxer-readahead-secs", "180")
            // L1 预防层：网络掉线时 libavformat 透明重连(连当前 URL)，瞬断在缓冲区内消化。
            // 只开 reconnect_on_network_error，不开 http_error——网盘 302 过期的 4xx/5xx 要
            // 上抛交给 Dart 层 L2 重解析重签，不能让 ffmpeg 死磕过期链把错误吞掉。
            // ⚠️ 绝不加 multiple_requests=1(大电影卡顿真凶,桌面早已删除,Android 之前漏同步)：
            // 本意是 keep-alive 复用连接，但对 302 跳转的网盘流(strm→115 CDN)会诱发大量分段
            // Range 请求，每段重走 302+重连+TLS 握手。curl 实测:连续流 28MB/s，分段 1.8MB/s(×15
            // 慢)；桌面 ffprobe 实测同一 MKV 默认 1.6s、加该参数 3m35s(×130)。删掉后走单条连续流。
            MPVLib.setOptionString("stream-lavf-o",
                "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=30")
            android.util.Log.i(TAG, "mpv disk cache: dir=$videoCacheDir fwd=$diskCacheForwardBytes back=$diskCacheBackBytes")
        } else {
            // 本地文件：无需大缓冲，沿用小额内存缓冲。
            MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
            MPVLib.setOptionString("demuxer-max-back-bytes", "32MiB")
        }

        // TLS
        val cacert = File(context.filesDir, "cacert.pem")
        if (cacert.exists()) {
            MPVLib.setOptionString("tls-verify", "yes")
            MPVLib.setOptionString("tls-ca-file", cacert.absolutePath)
        } else {
            MPVLib.setOptionString("tls-verify", "no")
            android.util.Log.w(TAG, "cacert.pem not found, disabling TLS verification")
        }

        // Misc
        MPVLib.setOptionString("save-position-on-quit", "no")
        // 日志级别：原 all=v(全模块 verbose) 让 mpv 起播爆发 ~200 条日志冲爆客户端消息队列
        // (`log message buffer overflow: 194 messages skipped`)，把 libass/fontconfig 的真实
        // 报错一并丢掉 → 远程无法定位"选了字幕轨仍不显示"。转发回调本就只放行 warn+，故降到
        // all=warn：App 日志一条不少、且不再溢出，libass 字体类报错(warn/error)得以浮出。
        // ass=v 单独放行 libass 的字体选择/字形渲染诊断（fontselect/glyph 等在 info/verbose
        // 级），其余模块仍锁 warn——既不触发起播 all=v 的 ~200 条溢出，又能在"选了字幕轨仍
        // 不显示"时看到 libass 到底是找不到字体、还是渲染了 0 个字形。定位后可撤回。
        MPVLib.setOptionString("msg-level", "all=warn,ass=v")
    }

    private fun getPlayer(playerId: String): MpvPlayerInstance? = players[playerId]

    private fun disposePlayer(playerId: String) {
        mainHandler.post {
            players.remove(playerId)?.release()
        }
    }

    fun disposeAll() {
        mainHandler.post {
            players.values.forEach { it.release() }
            players.clear()
        }
    }

    /**
     * Represents a single mpv player instance.
     * Implements MPVLib.EventObserver to receive property change callbacks
     * from the native event thread and forwards them to Flutter via EventChannel.
     */
    class MpvPlayerInstance(
        val playerId: String,
        private val context: Context,
        private val surface: Surface,
        private val mpvTexture: MpvTexture?,  // Nullable when using SurfaceView
        private val eventChannel: EventChannel,
        private val mainHandler: Handler
    ) : MPVLib.EventObserver, MPVLib.LogObserver {

        private var eventSink: EventChannel.EventSink? = null
        private var currentTracks: List<Map<String, Any>> = emptyList()
        // 诊断（字幕不显示定位）：sub-text 上升沿计数，捕捉"mpv 认为此刻该显示的字幕文本"，
        // 上限几条防刷屏。非空却看不见=渲染层(libass/OSD)问题；始终为空=解码/时间轴问题。
        private var lastSubText: String = ""
        private var subDiagCount = 0
        // 诊断"画面卡"：每 ~5s 落一次丢帧/实际帧率，判定是否解码跟不上(软解高分辨率典型)。
        private var lastDropLogSec = -100.0
        private var dropLogCount = 0

        init {
            eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    // 关键修复（内封字幕不显示）：轨道列表原本只在 FILE_LOADED 时经
                    // emitEvent("tracksChanged") 推送一次。若该事件在 Dart 订阅本 EventChannel
                    // 之前触发（局域网/快源 Emby 直连尤为常见，FILE_LOADED 抢在订阅前），这唯一
                    // 一次事件被投递到 null sink 后永久丢失 → Dart 侧 _tracks 整场为空 → 字幕选轨
                    // 退化成 sid=auto，内封字幕（SRT/ASS 文本 + PGS 图形）选不中/选错、表现为不显示。
                    // 订阅建立时立即回放最近一次已解析的轨道，消除该竞态。
                    if (currentTracks.isNotEmpty()) {
                        events?.success(mapOf("type" to "tracksChanged", "value" to currentTracks))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }

        // ---- Playback control ----

        fun play() {
            android.util.Log.i(TAG, "play() - setting pause=false")
            MPVLib.setPropertyBoolean("pause", false)
        }

        fun pause() {
            android.util.Log.i(TAG, "pause() - setting pause=true")
            MPVLib.setPropertyBoolean("pause", true)
        }

        fun seekTo(positionMs: Int) {
            MPVLib.command(arrayOf("seek", "${positionMs / 1000.0}", "absolute"))
        }

        fun reload(videoUrl: String, startPositionMs: Int) {
            // L2 原地重载：与 createPlayer 的加载逻辑一致——先用 start 属性定位再 loadfile
            // replace，避免 loadfile 后立刻 seek 落空的竞态。网络/缓存/重连等 mpv 选项已在
            // createPlayer 时写入同一 mpv 上下文，重载无需重设，直接复用。
            if (startPositionMs > 0) {
                MPVLib.setPropertyString("start", "${startPositionMs / 1000.0}")
            } else {
                MPVLib.setPropertyString("start", "none")
            }
            MPVLib.command(arrayOf("loadfile", videoUrl, "replace"))
            android.util.Log.i(TAG, "reload: loadfile replace from ${startPositionMs / 1000.0}s")
        }

        fun setSpeed(speed: Double) {
            val rate = speed.coerceIn(0.25, 4.0)
            // 倍速时始终以音频为主时钟并保留音调，避免视频追帧与 AudioTrack underrun
            // 互相触发，表现为画面/进度条周期性卡顿。
            MPVLib.setPropertyString("video-sync", "audio")
            MPVLib.setPropertyString("audio-pitch-correction", "yes")
            MPVLib.setPropertyString("interpolation", "no")
            MPVLib.setPropertyString("hdr-compute-peak", "no")
            MPVLib.setPropertyString("framedrop", if (rate > 1.0) "vo" else "no")
            MPVLib.setPropertyDouble("speed", rate)
        }

        fun setVolume(volume: Double) {
            // mpv volume range is 0-100, Flutter passes 0.0-1.0
            MPVLib.setPropertyDouble("volume", (volume * 100).coerceIn(0.0, 100.0))
        }

        fun getPosition(): Int {
            val pos = MPVLib.getPropertyDouble("time-pos") ?: return 0
            return (pos * 1000).toInt()
        }

        fun getDuration(): Int {
            val dur = MPVLib.getPropertyDouble("duration") ?: return 0
            return (dur * 1000).toInt().coerceAtLeast(0)
        }

        fun getVideoSize(): Map<String, Int> {
            val w = MPVLib.getPropertyInt("video-params/w") ?: 0
            val h = MPVLib.getPropertyInt("video-params/h") ?: 0
            return mapOf("width" to w, "height" to h)
        }

        // ---- Track management ----

        fun getTracksInfo(): List<Map<String, Any>> = currentTracks

        fun selectSubtitleTrack(trackId: String) {
            // sid 走属性接口设置（与下面 selectAudioTrack 的 aid 完全一致）。
            // 原写法 command("set_property", "sid", …) 是**无效命令**——mpv 命令接口里没有
            // "set_property"（那是 libmpv C API 函数名，非命令名）→ mpv 报
            // "Command 'set_property' not found" → sid 从未真正设上 → 选了字幕轨也不渲染。
            // 这是移动端内封字幕不显示的第二层根因（第一层是轨道投递竞态，见提交 26484fd）。
            MPVLib.setPropertyString("sid", trackId)
        }

        fun deselectSubtitleTrack() {
            MPVLib.setPropertyString("sid", "no")
        }

        fun selectAudioTrack(trackId: String) {
            MPVLib.setPropertyString("aid", trackId)
        }

        fun loadSubtitle(subtitleUrl: String, language: String) {
            MPVLib.command(arrayOf("sub-add", subtitleUrl, "auto", "external-sub", language))
        }

        // ---- Property access ----

        fun setProperty(name: String, value: String) {
            MPVLib.setPropertyString(name, value)
        }

        fun getProperty(name: String): String? {
            return MPVLib.getPropertyString(name)
        }

        fun getPropertyDouble(name: String): Double? {
            return MPVLib.getPropertyDouble(name)
        }

        fun command(args: Array<out String>) {
            MPVLib.command(args)
        }

        // ---- Screenshot ----

        fun screenshot(): ByteArray? {
            // 优先用 mpv 原生 screenshot-to-file 截「video」帧：按片源原始分辨率输出、
            // 宽高比正确、完整无裁切。grabThumbnail(1920) 会按固定边长缩放，导致
            // 截图比例失真 / 截不全（用户反馈的核心问题），仅作兜底。
            try {
                val tmp = java.io.File(
                    context.cacheDir,
                    "mpv_shot_${System.currentTimeMillis()}.jpg"
                )
                // 第三参数 "video"：只截解码后的视频帧（不含 OSD/字幕），原始分辨率。
                MPVLib.command(arrayOf("screenshot-to-file", tmp.absolutePath, "video"))
                if (tmp.exists() && tmp.length() > 0L) {
                    val bytes = tmp.readBytes()
                    tmp.delete()
                    return bytes
                }
                if (tmp.exists()) tmp.delete()
            } catch (e: Exception) {
                android.util.Log.w(
                    "MpvScreenshot",
                    "screenshot-to-file 失败，回退 grabThumbnail: ${e.message}"
                )
            }
            val bitmap = MPVLib.grabThumbnail(1920) ?: return null
            val stream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, stream)
            bitmap.recycle()
            return stream.toByteArray()
        }

        // ---- Aspect ratio ----

        fun setAspectRatio(ratio: String) {
            // 原生 mpv 在屏幕大小的 surface 里自行做缩放/letterbox，故比例由 mpv 属性控制：
            // video-aspect-override 改显示宽高比；keepaspect=no 变形拉伸铺满；panscan=1 保持
            // 比例放大裁切铺满。每个模式都把另外两项复位，避免上次模式残留。
            when (ratio) {
                "16:9" -> applyAspect(override = "16:9")
                "4:3" -> applyAspect(override = "4:3")
                "21:9" -> applyAspect(override = "21:9")
                "原始" -> applyAspect(override = "0") // 用片源原始比例
                "拉伸" -> applyAspect(override = "-1", keepAspect = false) // 变形铺满
                "铺满" -> applyAspect(override = "-1", panscan = 1.0) // 裁切铺满
                else -> applyAspect(override = "0") // 自适应 / 自动，使用媒体原始比例
            }
        }

        private fun applyAspect(
            override: String,
            keepAspect: Boolean = true,
            panscan: Double = 0.0,
        ) {
            try {
                MPVLib.setPropertyBoolean("keepaspect", keepAspect)
                MPVLib.setPropertyDouble("panscan", panscan)
                MPVLib.setPropertyString("video-aspect-override", override)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "applyAspect failed: ${e.message}")
            }
        }

        // ---- Release ----

        fun release() {
            MPVLib.removeObserver(this)
            MPVLib.removeLogObserver(this)

            // Detach surface from mpv (stops video rendering)
            try {
                MPVLib.setPropertyBoolean("force-window", false)
                MPVLib.detachSurface()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "detachSurface failed", e)
            }

            // Destroy mpv context
            try {
                MPVLib.destroy()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "MPVLib.destroy() failed", e)
            }

            // Release surface and Flutter texture
            // Note: When using SurfaceView, surface.release() is not needed
            // as the SurfaceView manages its own surface lifecycle
            try {
                surface.release()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "surface.release() failed (may be SurfaceView)", e)
            }
            mpvTexture?.dispose()
            eventSink = null
        }

        // ---- EventObserver implementation ----

        override fun eventProperty(property: String) {
            // NONE format — 属性变化通知（无值）。track-list 走这里：每次轨道增删/就绪
            // 都重新解析并推送 tracksChanged，保证 Dart 侧 _tracks 最终拿到完整内封字幕/音轨列表。
            when (property) {
                "track-list" -> loadTracks()
            }
        }

        override fun eventProperty(property: String, value: Long) {
            when (property) {
                "video-params/w", "video-params/h" -> {
                    emitVideoSize()
                }
            }
        }

        override fun eventProperty(property: String, value: Boolean) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "pause" -> emitEvent("playing", !value)
                "paused-for-cache" -> emitEvent("buffering", value)
                // 不再用 eof-reached / idle-active 属性推断"播放完成"。
                // seek（尤其向前 seek）或缓冲枯竭时 mpv 会把 eof-reached 瞬时置 true，
                // 用它发 completed 会被上层当成"播放结束"→停止播放、画面消失、进度条停在
                // seek 点，正是"重新 seek 续播后没画面"的根因。真正的结束只认 END_FILE 事件。
            }
        }

        override fun eventProperty(property: String, value: String) {
            when (property) {
                "hwdec-current" -> {
                    // 诊断"画面卡"：把实际生效的解码路径落日志(warn 级，穿过起播后静默)。
                    // no/空 = 软解(高分辨率会卡)；mediacodec/mediacodec-copy = 硬解生效。
                    emitEvent(
                        "log",
                        mapOf(
                            "level" to MPVLib.MpvLogLevel.WARN,
                            "prefix" to "decode-diag",
                            "text" to "hwdec-current=$value vd=${MPVLib.getPropertyString("video-codec")}"
                        )
                    )
                }
                "sub-text" -> {
                    // 上升沿(空→非空)时，把 mpv 判定应显示的字幕文本 + 关键渲染几何一并落日志。
                    // 若这里有文本但屏幕空白 → 字幕已解码、卡在渲染层(libass/OSD)。若整场从不触发
                    // → 解码/时间轴问题(subrip 没产出文本 / sid 没真生效)。上限 3 条防刷屏。
                    if (value.isNotEmpty() && lastSubText.isEmpty() && subDiagCount < 3) {
                        subDiagCount++
                        val subScale = MPVLib.getPropertyString("sub-scale")
                        val subPos = MPVLib.getPropertyString("sub-pos")
                        val subFont = MPVLib.getPropertyString("sub-font")
                        val osdDim = MPVLib.getPropertyString("osd-dimensions")
                        emitEvent(
                            "log",
                            mapOf(
                                "level" to MPVLib.MpvLogLevel.WARN,
                                "prefix" to "sub-text-diag",
                                "text" to "#$subDiagCount 应显示=\"${value.take(40)}\" " +
                                    "scale=$subScale pos=$subPos font=$subFont osd=$osdDim"
                            )
                        )
                    }
                    lastSubText = value
                }
            }
        }

        override fun eventProperty(property: String, value: Double) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "time-pos" -> {
                    emitEvent("timePos", (value * 1000).toLong())
                    // 每 ~5s 采一次解码/丢帧诊断，前 6 次即可看出趋势(上限防刷屏)。
                    if (value - lastDropLogSec >= 5.0 && dropLogCount < 6) {
                        lastDropLogSec = value
                        dropLogCount++
                        emitEvent(
                            "log",
                            mapOf(
                                "level" to MPVLib.MpvLogLevel.WARN,
                                "prefix" to "decode-diag",
                                // drop-* 高 → 解码/渲染跟不上；cache-* 空/paused-for-cache=yes
                                // → 取流/缓存跟不上(网络或磁盘写回瓶颈)。两者区分"卡"的真因。
                                "text" to "t=${value.toInt()}s ${MPVLib.getPropertyString("video-params/w")}x${MPVLib.getPropertyString("video-params/h")} " +
                                    "hwdec=${MPVLib.getPropertyString("hwdec-current")} " +
                                    "drop-dec=${MPVLib.getPropertyString("frame-drop-count")} " +
                                    "drop-vo=${MPVLib.getPropertyString("decoder-frame-drop-count")} " +
                                    "fps=${MPVLib.getPropertyString("estimated-vf-fps")} " +
                                    "paused-cache=${MPVLib.getPropertyString("paused-for-cache")} " +
                                    "cache-secs=${MPVLib.getPropertyString("demuxer-cache-duration")} " +
                                    "cache-spd=${MPVLib.getPropertyString("cache-speed")}"
                            )
                        )
                    }
                }
                "duration" -> emitEvent("duration", (value * 1000).toLong())
                "speed" -> emitEvent("speed", value)
                "volume" -> emitEvent("volume", value / 100.0) // normalize to 0-1
            }
        }

        // ---- LogObserver implementation ----

        // mpv 自身的日志（来自 libmpv，经 libplayer.so 回调）。原本无人订阅，导致
        // 原生崩溃前的「最后遗言」全部丢失、用户导出的日志里什么都没有。这里订阅并把
        // 警告/错误/致命级别转发到 Flutter 侧 AppLogger 落盘，便于崩溃后取证。
        // mpv 级别：FATAL=10 ERROR=20 WARN=30 INFO=40 V=50 DEBUG=60 TRACE=70，数字越小越严重。
        override fun logMessage(prefix: String, level: Int, text: String) {
            // 默认只转 warn+ 避免刷屏；但 libass 的字体选择/字形诊断在 V(50) 级，配合
            // msg-level=ass=v 时放行 ass 前缀到 V，定位"选了字幕轨仍不显示"。定位后连同
            // msg-level 的 ass=v 一起撤回。
            val allow = level <= MPVLib.MpvLogLevel.WARN ||
                (prefix == "ass" && level <= MPVLib.MpvLogLevel.V)
            if (!allow) return
            val trimmed = text.trimEnd()
            if (trimmed.isEmpty()) return
            emitEvent(
                "log",
                mapOf("level" to level, "prefix" to prefix, "text" to trimmed)
            )
        }

        override fun event(eventId: Int) {
            android.util.Log.d(TAG, "mpv event: $eventId")
            when (eventId) {
                MPVLib.MpvEvent.START_FILE -> {
                    android.util.Log.i(TAG, "START_FILE")
                }
                MPVLib.MpvEvent.FILE_LOADED -> {
                    android.util.Log.i(TAG, "FILE_LOADED — emitting tracks and duration")
                    emitEvent("buffering", false)
                    loadTracks()

                    // 诊断日志：检查当前音频和字幕状态
                    val audioCodec = MPVLib.getPropertyString("audio-codec")
                    val audioCodecName = MPVLib.getPropertyString("audio-codec-name")
                    val currentAid = MPVLib.getPropertyInt("aid")
                    val currentSid = MPVLib.getPropertyInt("sid")
                    val subVisibility = MPVLib.getPropertyBoolean("sub-visibility")
                    val audioChannels = MPVLib.getPropertyString("audio-channels")
                    android.util.Log.i(TAG, "FILE_LOADED diagnostics:")
                    android.util.Log.i(TAG, "  audio-codec: $audioCodec")
                    android.util.Log.i(TAG, "  audio-codec-name: $audioCodecName")
                    android.util.Log.i(TAG, "  current aid: $currentAid")
                    android.util.Log.i(TAG, "  current sid: $currentSid")
                    android.util.Log.i(TAG, "  sub-visibility: $subVisibility")
                    android.util.Log.i(TAG, "  audio-channels: $audioChannels")

                    // 把字幕关键诊断转发到 App 日志（logMessage 只转 mpv 自身消息，且常被
                    // 缓冲区溢出丢弃；这条直发保证用户导出的日志里一定有，便于远程定位
                    // "选了字幕轨仍不显示"到底卡在哪：sid 有没有生效 / 可见性 / 轨道 codec）。
                    val subTracks = currentTracks.filter {
                        it["type"] == "text" || it["type"] == "bitmap"
                    }
                    val subSummary = subTracks.joinToString("; ") {
                        "id=${it["id"]} ${it["type"]} codec=${it["codec"]} sel=${it["isSelected"]}"
                    }
                    emitEvent(
                        "log",
                        mapOf(
                            "level" to MPVLib.MpvLogLevel.WARN,
                            "prefix" to "sub-diag",
                            "text" to "sid=$currentSid sub-visibility=$subVisibility " +
                                "共${subTracks.size}条字幕轨 [$subSummary] | ${MpvPlayerPlugin.lastFontStatus}"
                        )
                    )

                    // 检查解码器列表
                    val decoderList = MPVLib.getPropertyString("decoder-list")
                    if (decoderList != null) {
                        val hasTruehd = decoderList.contains("truehd", ignoreCase = true)
                        val hasSubrip = decoderList.contains("subrip", ignoreCase = true)
                        val hasSrt = decoderList.contains("srt", ignoreCase = true)
                        val hasAss = decoderList.contains("ass", ignoreCase = true)
                        android.util.Log.i(TAG, "  decoder-list contains truehd: $hasTruehd")
                        android.util.Log.i(TAG, "  decoder-list contains subrip: $hasSubrip")
                        android.util.Log.i(TAG, "  decoder-list contains srt: $hasSrt")
                        android.util.Log.i(TAG, "  decoder-list contains ass: $hasAss")
                        // 打印前500字符的解码器列表
                        android.util.Log.i(TAG, "  decoder-list (first 500): ${decoderList.take(500)}")
                    }

                    val dur = MPVLib.getPropertyDouble("duration")
                    if (dur != null && dur > 0) {
                        emitEvent("duration", (dur * 1000).toLong())
                    }
                }
                MPVLib.MpvEvent.END_FILE -> {
                    android.util.Log.i(TAG, "END_FILE — emitting completed")
                    val reason = MPVLib.getPropertyInt("eof-reached")
                    emitEvent("completed", true)
                }
                MPVLib.MpvEvent.VIDEO_RECONFIG -> {
                    emitVideoSize()
                }
            }
        }

        // ---- Track parsing ----

        private fun loadTracks() {
            try {
                val count = MPVLib.getPropertyInt("track-list/count") ?: 0
                val trackList = mutableListOf<Map<String, Any>>()

                for (i in 0 until count) {
                    val type = MPVLib.getPropertyString("track-list/$i/type") ?: continue
                    val id = MPVLib.getPropertyInt("track-list/$i/id") ?: continue
                    val lang = MPVLib.getPropertyString("track-list/$i/lang") ?: ""
                    val title = MPVLib.getPropertyString("track-list/$i/title") ?: ""
                    val codec = MPVLib.getPropertyString("track-list/$i/codec") ?: ""
                    val selected = MPVLib.getPropertyBoolean("track-list/$i/selected") ?: false

                    val resolvedType = when (type) {
                        "video" -> "video"
                        "audio" -> "audio"
                        "sub" -> {
                            // Detect bitmap subtitles by codec
                            if (codec.contains("pgs", ignoreCase = true) ||
                                codec.contains("hdmv", ignoreCase = true) ||
                                codec.contains("dvd_subtitle", ignoreCase = true)) {
                                "bitmap"
                            } else {
                                "text"
                            }
                        }
                        else -> type
                    }

                    val isAss = codec.contains("ass", ignoreCase = true) ||
                            codec.contains("ssa", ignoreCase = true)

                    trackList.add(mapOf(
                        "id" to id.toString(),
                        "type" to resolvedType,
                        "language" to lang,
                        // title 与 label 都带上：内封字幕智能选轨的匹配器读的是 t["title"]
                        // （见 player_subtitle_loader.matchMpvSubtitleTrack），原来只塞了 "label"
                        // → 多条同语言内封轨（简/繁/简日/特效）按标题消歧全部失效 → 选错或选不中。
                        "title" to title,
                        "label" to title,
                        "codec" to codec,
                        "isAss" to isAss,
                        "isBitmap" to (resolvedType == "bitmap"),
                        "isSelected" to selected
                    ))
                }

                currentTracks = trackList
                emitEvent("tracksChanged", trackList)
            } catch (e: Exception) {
                android.util.Log.e(TAG, "loadTracks failed", e)
            }
        }

        private fun emitVideoSize() {
            val w = MPVLib.getPropertyInt("video-params/w") ?: return
            val h = MPVLib.getPropertyInt("video-params/h") ?: return
            if (w > 0 && h > 0) {
                // Don't update SurfaceTexture buffer — let mpv handle aspect ratio
                // and letterboxing internally at the surface's native dimensions
                emitEvent("videoSize", mapOf("width" to w, "height" to h))
            }
        }

        private fun emitEvent(type: String, value: Any?) {
            mainHandler.post {
                eventSink?.success(mapOf("type" to type, "value" to value))
            }
        }
    }
}
