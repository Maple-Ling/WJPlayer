package com.mapleling.wjplayer

import android.util.Log
import io.flutter.view.TextureRegistry

/**
 * Helper for managing the Flutter texture lifecycle for mpv video output.
 *
 * The actual Surface is created by MpvPlayerPlugin and passed to
 * MPVLib.attachSurface(). This class only manages the TextureRegistry entry.
 */
class MpvTexture(
    val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry
) {
    fun dispose() {
        surfaceTextureEntry.release()
        Log.i("MpvTexture", "MPV texture disposed")
    }
}
