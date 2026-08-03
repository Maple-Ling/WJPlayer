package com.mapleling.wjplayer

import android.content.Context
import android.util.AttributeSet
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import `is`.xyz.mpv.MPVLib

/**
 * Custom SurfaceView for mpv video rendering.
 *
 * This view provides a SurfaceHolder that mpv can render to via gpu-next.
 * Unlike SurfaceTexture (used with Flutter's Texture widget), SurfaceView
 * provides a proper window-backed surface that supports gpu-next's libplacebo
 * rendering pipeline.
 */
class MpvSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : SurfaceView(context, attrs, defStyleAttr), SurfaceHolder.Callback {

    companion object {
        private const val TAG = "MpvSurfaceView"
    }

    var onSurfaceReady: ((Surface) -> Unit)? = null
    var onSurfaceChanged: ((Int, Int) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    private var isAttachedToMpv = false
    private var pendingAttach = false  // Flag to attach when surface becomes ready
    private var mpvInitialized = false  // Flag: mpv has been initialized, auto-reattach on surfaceCreated

    init {
        holder.addCallback(this)
        // Set format to RGBA_8888 for best compatibility
        holder.setFormat(android.graphics.PixelFormat.RGBA_8888)
        // Place SurfaceView between Flutter background and foreground layers
        // Works with Hybrid Composition (initExpensiveAndroidView)
        setZOrderMediaOverlay(true)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        android.util.Log.i(TAG, "surfaceCreated: ${holder.surfaceFrame}, pendingAttach=$pendingAttach, mpvInitialized=$mpvInitialized")
        onSurfaceReady?.invoke(holder.surface)

        // If we have a pending attach request, do it now
        if (pendingAttach) {
            android.util.Log.i(TAG, "Surface ready, performing pending attach to mpv")
            attachToMpv()
            pendingAttach = false
        } else if (mpvInitialized && !isAttachedToMpv) {
            // Surface was recreated by Flutter's virtual display — reattach to mpv
            android.util.Log.i(TAG, "Surface recreated, re-attaching to mpv")
            attachToMpv()
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        android.util.Log.i(TAG, "surfaceChanged: ${width}x$height, format=$format, isAttached=$isAttachedToMpv")
        // Notify mpv of the new surface size
        if (isAttachedToMpv) {
            MPVLib.setPropertyString("android-surface-size", "${width}x$height")
        }
        onSurfaceChanged?.invoke(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        android.util.Log.i(TAG, "surfaceDestroyed, wasAttached=$isAttachedToMpv")
        // Detach from mpv but keep mpvInitialized=true so surfaceCreated auto-reattaches
        if (isAttachedToMpv) {
            try {
                MPVLib.detachSurface()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "Error detaching surface on destroy: ${e.message}")
            }
            isAttachedToMpv = false
        }
        onSurfaceDestroyed?.invoke()
    }

    fun attachToMpv() {
        val surface = holder.surface
        if (surface.isValid) {
            android.util.Log.i(TAG, "Attaching surface to mpv, surface=${surface}, isValid=${surface.isValid}")
            MPVLib.attachSurface(surface)
            val frame = holder.surfaceFrame
            MPVLib.setPropertyString("android-surface-size", "${frame.width()}x${frame.height()}")
            isAttachedToMpv = true
            mpvInitialized = true
            android.util.Log.i(TAG, "Surface attached successfully, size=${frame.width()}x${frame.height()}")
        } else {
            // Surface not ready yet, mark for pending attach
            android.util.Log.w(TAG, "Surface not ready, marking for pending attach, surface=${surface}")
            pendingAttach = true
            mpvInitialized = true
        }
    }

    fun detachFromMpv() {
        if (isAttachedToMpv) {
            android.util.Log.i(TAG, "Detaching surface from mpv")
            try {
                MPVLib.detachSurface()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "Error detaching surface: ${e.message}")
            }
            isAttachedToMpv = false
            mpvInitialized = false  // Full detach — no auto-reattach
            android.util.Log.i(TAG, "Surface detached successfully")
        } else {
            android.util.Log.d(TAG, "detachFromMpv called but was not attached")
        }
    }

    fun isSurfaceValid(): Boolean = holder.surface.isValid

    fun getStatus(): String {
        return "MpvSurfaceView[isValid=${holder.surface.isValid}, isAttached=$isAttachedToMpv, pendingAttach=$pendingAttach]"
    }
}
