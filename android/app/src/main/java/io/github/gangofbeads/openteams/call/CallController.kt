package io.github.gangofbeads.openteams.call

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.util.Base64
import android.view.KeyEvent
import io.github.gangofbeads.openteams.MainActivity
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.R
import io.github.gangofbeads.openteams.Settings
import io.github.gangofbeads.openteams.TeamsService
import io.github.gangofbeads.openteams.share.ScreenShare
import io.github.gangofbeads.openteams.web.TeamsWeb
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Call state as reported by open-teams' activityHub/speakingIndicator in the
 * page, and the native side of it: Telecom connection, call notifications,
 * foreground service and the in-call controls. Main thread only.
 */
object CallController {
    class Incoming(val caller: String, val subtitle: String, val avatar: Bitmap?)

    var incoming: Incoming? = null
        private set
    var inCall = false
        private set
    var callStartedAt = 0L
        private set

    /** "speaking" | "silent" | "muted" | "off", from speakingIndicator.js. */
    var microphoneState = "off"
        private set
    var cameraOn = false
        private set
    val muted get() = microphoneState == "muted"

    var connection: TeamsConnection? = null
        private set

    private val app get() = OpenTeamsApp.instance
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private var mutedForHold = false

    // Teams' calling shortcuts, as in app/control/teamsControlService.js (plus Ctrl+Shift+E to share).
    private val shortcutKeys = mapOf(
        "mute" to KeyEvent.KEYCODE_M,
        "video" to KeyEvent.KEYCODE_O,
        "hangup" to KeyEvent.KEYCODE_H,
        "raiseHand" to KeyEvent.KEYCODE_K,
        "share" to KeyEvent.KEYCODE_E,
    )

    // Answering in the Teams page dismisses its toast before call-connected arrives.
    private val endUnansweredConnection = Runnable {
        if (!inCall) {
            connection?.end(DisconnectCause.MISSED)
            connection = null
        }
    }

    fun addListener(listener: () -> Unit) = listeners.add(listener)

    fun removeListener(listener: () -> Unit) = listeners.remove(listener)

    private fun changed() {
        listeners.forEach { it() }
        TeamsService.update(app)
    }

    fun onIncomingCall(data: JSONObject) {
        val details = data.optJSONObject("details") ?: JSONObject()
        val caller = listOf(data.optString("caller"), details.optString("name"), details.optString("number"))
            .firstOrNull { it.isNotBlank() } ?: app.getString(R.string.unknown_caller)
        val subtitle = listOf(details.optString("number"), details.optString("queue"))
            .filter { it.isNotBlank() && it != caller }
            .joinToString(" · ")
            .ifBlank { app.getString(R.string.incoming_teams_call) }
        // Call queues send a second toast once the caller is known: update, don't ring again.
        val alreadyRinging = incoming != null
        incoming = Incoming(caller, subtitle, decodeDataImage(data.optString("image")))
        main.removeCallbacks(endUnansweredConnection)
        if (alreadyRinging || !Telecom.addIncomingCall(app, caller)) showIncomingUi()
    }

    /** TeamsService posts the ringing notification and its full-screen intent. */
    fun showIncomingUi() = changed()

    fun answer(video: Boolean) {
        if (incoming == null) return
        incoming = null
        TeamsWeb.bridge.emit("incoming-call-action", if (video) "ACCEPT_VIDEO" else "ACCEPT_AUDIO")
        connection?.preferSpeaker = video
        connection?.setActive()
        MainActivity.bringToFront(app)
        changed()
    }

    fun decline() {
        if (incoming == null) return
        incoming = null
        TeamsWeb.bridge.emit("incoming-call-action", "DECLINE")
        connection?.end(DisconnectCause.REJECTED)
        connection = null
        changed()
    }

    fun onIncomingCallEnded() {
        if (incoming == null) return
        incoming = null
        main.postDelayed(endUnansweredConnection, 5_000)
        changed()
    }

    fun onCallConnected() {
        main.removeCallbacks(endUnansweredConnection)
        if (inCall) return
        inCall = true
        callStartedAt = System.currentTimeMillis()
        val current = connection
        if (current != null) current.setActive() else Telecom.placeOutgoingCall(app)
        changed()
    }

    fun onCallDisconnected() {
        main.removeCallbacks(endUnansweredConnection)
        if (!inCall && connection == null) return
        inCall = false
        microphoneState = "off"
        cameraOn = false
        mutedForHold = false
        if (connection == null) AudioRoutes.reset(app)
        connection?.end(DisconnectCause.LOCAL)
        connection = null
        ScreenShare.stop()
        changed()
    }

    fun attach(newConnection: TeamsConnection) {
        connection = newConnection
        when {
            inCall -> newConnection.setActive()
            incoming == null && newConnection.state == android.telecom.Connection.STATE_DIALING -> {
                // The call ended before Telecom created the connection.
                newConnection.end(DisconnectCause.LOCAL)
                connection = null
            }
        }
    }

    fun onConnectionFailed() {
        connection = null
        if (incoming != null) showIncomingUi()
    }

    /** In-call button: clicks Teams' own control, falling back to its keyboard shortcut. */
    fun control(action: String) = TeamsWeb.bridge.emit("call-control", action)

    fun onControlResult(action: String, handled: Boolean) {
        if (!handled) shortcutKeys[action]?.let(TeamsWeb::sendShortcut)
    }

    /** Mute requested by the system (headset button, car kit, hold). */
    fun setMuted(mute: Boolean) {
        if (inCall && microphoneState != "off" && muted != mute) control("mute")
    }

    fun hold(on: Boolean) {
        if (on) {
            mutedForHold = !muted
            setMuted(true)
            connection?.setOnHold()
        } else {
            if (mutedForHold) setMuted(false)
            mutedForHold = false
            connection?.setActive()
        }
    }

    fun hangUpFromSystem() {
        if (incoming != null) decline() else control("hangup")
    }

    fun onMicrophoneState(state: String) {
        val wasMuted = muted
        microphoneState = state
        if (wasMuted != muted) changed()
    }

    fun onCameraState(on: Boolean) {
        if (cameraOn == on) return
        cameraOn = on
        changed()
    }

    fun onAudioRouteChanged() = listeners.forEach { it() }

    private fun decodeDataImage(src: String): Bitmap? {
        if (!src.startsWith("data:image/")) return null
        return runCatching {
            val bytes = Base64.decode(src.substringAfter(','), Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()
    }
}
