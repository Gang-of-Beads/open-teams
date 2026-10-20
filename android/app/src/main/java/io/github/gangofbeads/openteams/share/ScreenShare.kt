package io.github.gangofbeads.openteams.share

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.TeamsService
import io.github.gangofbeads.openteams.web.TeamsWeb
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import kotlin.math.max

/**
 * getDisplayMedia() for Teams (WebView has none): MediaProjection mirrors the
 * screen into an ImageReader and JPEG frames go to the page, where
 * android-preload.js draws them on a canvas and hands Teams its captureStream().
 */
object ScreenShare {
    private const val TAG = "ScreenShare"
    private const val MAX_EDGE = 1280
    private const val FPS = 10
    private const val JPEG_QUALITY = 70

    var active = false
        private set

    private var pendingReply: ((Any?) -> Unit)? = null
    private var consent: Intent? = null
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null

    /** From the page: ask the user, MainActivity returns the consent to [onConsent]. */
    fun request(reply: (Any?) -> Unit) {
        val activity = TeamsWeb.host
        if (active || activity == null || !TeamsWeb.bridge.canPostFrames()) {
            reply(JSONObject().put("ok", false))
            return
        }
        pendingReply = reply
        activity.requestScreenCapture()
    }

    fun onConsent(resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingReply?.invoke(JSONObject().put("ok", false))
            pendingReply = null
            return
        }
        consent = data
        active = true
        // Android 14 requires the mediaProjection foreground service before getMediaProjection().
        TeamsService.update(OpenTeamsApp.instance)
    }

    /** Called by TeamsService once it is in the foreground with the mediaProjection type. */
    fun onForegroundReady(context: Context) {
        val data = consent ?: return
        consent = null
        val reply = pendingReply
        pendingReply = null
        try {
            start(context, data)
            reply?.invoke(JSONObject().put("ok", true).put("width", reader!!.width).put("height", reader!!.height).put("fps", FPS))
        } catch (e: Exception) {
            Log.w(TAG, "screen capture failed", e)
            reply?.invoke(JSONObject().put("ok", false))
            stop()
        }
    }

    private fun start(context: Context, data: Intent) {
        val metrics = context.resources.displayMetrics
        val scale = MAX_EDGE.toFloat() / max(metrics.widthPixels, metrics.heightPixels)
        val width = (metrics.widthPixels * scale).toInt() and 1.inv()
        val height = (metrics.heightPixels * scale).toInt() and 1.inv()
        val worker = HandlerThread("screen-share").also { it.start() }
        val handler = Handler(worker.looper)
        thread = worker

        val manager = context.getSystemService(MediaProjectionManager::class.java)
        val mediaProjection = manager.getMediaProjection(Activity.RESULT_OK, data) ?: error("consent no longer valid")
        mediaProjection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Handler(context.mainLooper).post { stop() }
            }
        }, handler)
        projection = mediaProjection

        val imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        reader = imageReader
        var lastFrame = 0L
        var bitmap: Bitmap? = null
        val jpeg = ByteArrayOutputStream()
        imageReader.setOnImageAvailableListener({ source ->
            val image = source.acquireLatestImage() ?: return@setOnImageAvailableListener
            image.use {
                val now = SystemClock.uptimeMillis()
                if (now - lastFrame < 1000L / FPS) return@setOnImageAvailableListener
                lastFrame = now
                val plane = it.planes[0]
                val paddedWidth = plane.rowStride / plane.pixelStride
                val frame = bitmap?.takeIf { b -> b.width == paddedWidth }
                    ?: Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888).also { b -> bitmap = b }
                frame.copyPixelsFromBuffer(plane.buffer)
                jpeg.reset()
                Bitmap.createBitmap(frame, 0, 0, width, height).apply {
                    compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, jpeg)
                    recycle()
                }
                TeamsWeb.bridge.postFrame(jpeg.toByteArray())
            }
        }, handler)

        display = mediaProjection.createVirtualDisplay(
            "open-teams-share", width, height, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, imageReader.surface, null, handler,
        )
    }

    fun stop() {
        if (!active) return
        active = false
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection?.stop()
        projection = null
        thread?.quitSafely()
        thread = null
        consent = null
        TeamsWeb.bridge.emit("screen-share-ended")
        TeamsService.update(OpenTeamsApp.instance)
    }
}
