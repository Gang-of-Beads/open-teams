package io.github.gangofbeads.openteams.web

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.github.gangofbeads.openteams.Notifications
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.Settings
import io.github.gangofbeads.openteams.call.CallController
import io.github.gangofbeads.openteams.share.ScreenShare
import org.json.JSONArray
import org.json.JSONObject

/**
 * Native end of the ipcRenderer shim in android-preload.js. Channel names are
 * the ones open-teams' browser modules already use with Electron's main
 * process; the Android-only ones are listed in android/README.md.
 */
class WebBridge : WebViewCompat.WebMessageListener {
    private val main = Handler(Looper.getMainLooper())
    private var proxy: JavaScriptReplyProxy? = null

    /** Teams' shell as last reported by the page, for the native bars and drawer. */
    var shellState: ShellState? = null
        private set
    var avatar: Bitmap? = null
        private set
    var onShellChanged: (() -> Unit)? = null

    override fun onPostMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        replyProxy: JavaScriptReplyProxy,
    ) {
        if (!isMainFrame || !TeamsHosts.isAppOrigin(sourceOrigin)) return
        proxy = replyProxy
        val json = runCatching { JSONObject(message.data ?: return) }.getOrNull() ?: return
        val channel = json.optString("channel")
        val args = json.optJSONArray("args") ?: JSONArray()
        when (json.optString("type")) {
            "hello" -> {
                TeamsWeb.pageReady = true
                shellState = null
                onShellChanged?.invoke()
            }
            "send" -> onSend(channel, args)
            "invoke" -> {
                val id = json.optInt("id")
                onInvoke(channel, args) { result ->
                    val reply = JSONObject().put("type", "reply").put("id", id).put("result", result ?: JSONObject.NULL)
                    main.post { runCatching { replyProxy.postMessage(reply.toString()) } }
                }
            }
        }
    }

    fun emit(channel: String, vararg args: Any?) {
        val payload = JSONArray()
        args.forEach { payload.put(it ?: JSONObject.NULL) }
        val message = JSONObject().put("type", "event").put("channel", channel).put("args", payload).toString()
        main.post { runCatching { proxy?.postMessage(message) } }
    }

    fun canPostFrames() = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_ARRAY_BUFFER)

    fun postFrame(jpeg: ByteArray) {
        main.post { runCatching { proxy?.postMessage(jpeg) } }
    }

    private fun onInvoke(channel: String, args: JSONArray, reply: (Any?) -> Unit) {
        val app = OpenTeamsApp.instance
        when (channel) {
            "get-config" -> reply(Settings.webConfig())
            // activityManager.js keeps the user "Available" for both states (awayOnSystemIdle is off).
            "get-system-idle-state" -> {
                val interactive = (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
                reply(JSONObject().put("system", if (interactive) "active" else "locked").put("userIdle", 0).put("userCurrent", 0))
            }
            "show-notification" -> {
                args.optJSONObject(0)?.let { Notifications.showMessage(app, it) }
                reply(null)
            }
            "incoming-call-created" -> {
                CallController.onIncomingCall(args.optJSONObject(0) ?: JSONObject())
                reply(null)
            }
            "incoming-call-ended" -> {
                CallController.onIncomingCallEnded()
                reply(null)
            }
            "call-connected" -> {
                CallController.onCallConnected()
                reply(null)
            }
            "call-disconnected" -> {
                CallController.onCallDisconnected()
                reply(null)
            }
            "screen-share-start" -> ScreenShare.request(reply)
            else -> {
                Log.d(TAG, "unhandled invoke $channel")
                reply(null)
            }
        }
    }

    private fun onSend(channel: String, args: JSONArray) {
        when (channel) {
            "microphone-state-changed" -> CallController.onMicrophoneState(args.optString(0))
            "camera-state-changed" -> CallController.onCameraState(args.optBoolean(0))
            "call-control-result" -> args.optJSONObject(0)?.let {
                CallController.onControlResult(it.optString("action"), it.optBoolean("handled"))
            }
            "show-keyboard" -> TeamsWeb.webView?.let {
                it.requestFocus()
                it.context.getSystemService(InputMethodManager::class.java).showSoftInput(it, 0)
            }
            "shell-state" -> args.optJSONObject(0)?.let {
                val state = ShellState.parse(it)
                // theme.js can apply the OS theme once Teams' shell has rendered.
                if (shellState?.apps.isNullOrEmpty() && state.apps.isNotEmpty()) emitSystemTheme()
                shellState = state
                onShellChanged?.invoke()
            }
            "profile-avatar" -> {
                val data = args.optString(0)
                if (data.startsWith("data:image/")) {
                    val bytes = android.util.Base64.decode(data.substringAfter(','), android.util.Base64.DEFAULT)
                    avatar = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    onShellChanged?.invoke()
                }
            }
            "screen-share-stop" -> ScreenShare.stop()
            "save-file" -> args.optJSONObject(0)?.let { Downloads.saveDataUrl(it.optString("name"), it.optString("dataUrl")) }
            "deep-link-fallback" -> {
                val url = Uri.parse(args.optString(0))
                if (TeamsHosts.isAppOrigin(url)) TeamsWeb.webView?.loadUrl(url.toString())
            }
            else -> Log.d(TAG, "unhandled send $channel")
        }
    }

    /** theme.js applies the OS theme once Teams' client preferences exist. */
    fun emitSystemTheme() {
        val night = OpenTeamsApp.instance.resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        emit("system-theme-changed", night)
    }

    private companion object {
        const val TAG = "WebBridge"
    }
}
