package com.mapleling.wjplayer

import android.content.Context
import android.view.View
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec

/**
 * Factory for creating MpvSurfaceView instances that Flutter can embed
 * using AndroidView widget.
 */
class MpvSurfaceViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    companion object {
        private const val TAG = "MpvSurfaceViewFactory"
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String, Any?> ?: emptyMap()
        // Use the surfaceViewId from creation params if provided, otherwise use Flutter's viewId
        // Dart 传过来的 int 在 Android 端可能是 Long，用 Number 兼容
        val surfaceViewId = (creationParams["surfaceViewId"] as? Number)?.toInt() ?: viewId
        android.util.Log.i(TAG, "Creating platform view: surfaceViewId=$surfaceViewId, flutterViewId=$viewId")
        return MpvSurfacePlatformView(context, surfaceViewId, creationParams)
    }
}

/**
 * PlatformView wrapper for MpvSurfaceView.
 */
class MpvSurfacePlatformView(
    private val context: Context,
    private val surfaceViewId: Int,
    private val creationParams: Map<String, Any?>
) : PlatformView {

    private val surfaceView: MpvSurfaceView = MpvSurfaceView(context)

    init {
        // Store reference in the companion object for access from MpvPlayerPlugin
        views[surfaceViewId] = surfaceView
        android.util.Log.i("MpvSurfacePlatformView", "Registered view with surfaceViewId=$surfaceViewId")
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        views.remove(surfaceViewId)
        surfaceView.detachFromMpv()
        android.util.Log.i("MpvSurfacePlatformView", "Disposed view with surfaceViewId=$surfaceViewId")
    }

    companion object {
        // Store references to active views by surfaceViewId
        val views = mutableMapOf<Int, MpvSurfaceView>()
    }
}
