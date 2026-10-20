package io.github.gangofbeads.openteams.call

import android.Manifest
import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.CallEndpoint
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.github.gangofbeads.openteams.R
import io.github.gangofbeads.openteams.Settings

/**
 * Registers Teams calls with Android Telecom as self-managed calls, so the
 * system treats them as phone calls: Bluetooth headset and car kit
 * answer/hang-up, audio routing, call waiting against cellular calls.
 */
object Telecom {
    private const val TAG = "Telecom"
    private const val ACCOUNT_ID = "open-teams"

    private fun handle(context: Context) =
        PhoneAccountHandle(ComponentName(context, TeamsConnectionService::class.java), ACCOUNT_ID)

    // FEATURE_TELECOM replaced FEATURE_CONNECTION_SERVICE on 33; newer devices only declare the former.
    @Suppress("DEPRECATION")
    private val telecomFeature =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) PackageManager.FEATURE_TELECOM else PackageManager.FEATURE_CONNECTION_SERVICE

    private fun available(context: Context) =
        Settings.telecom &&
            context.packageManager.hasSystemFeature(telecomFeature) &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.MANAGE_OWN_CALLS) == PackageManager.PERMISSION_GRANTED

    fun register(context: Context) {
        if (!available(context)) return
        val account = PhoneAccount.builder(handle(context), context.getString(R.string.app_name))
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
            .addSupportedUriScheme(PhoneAccount.SCHEME_SIP)
            .build()
        runCatching { context.getSystemService(TelecomManager::class.java).registerPhoneAccount(account) }
            .onFailure { Log.w(TAG, "registerPhoneAccount failed", it) }
    }

    /** True when Telecom took the call; it then asks for the ringing UI via onShowIncomingCallUi. */
    fun addIncomingCall(context: Context, caller: String): Boolean {
        if (!available(context)) return false
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts(PhoneAccount.SCHEME_SIP, caller, null))
        }
        return runCatching { context.getSystemService(TelecomManager::class.java).addNewIncomingCall(handle(context), extras) }
            .onFailure { Log.w(TAG, "addNewIncomingCall failed", it) }
            .isSuccess
    }

    /** A call started in the Teams page (outgoing or meeting join). */
    @SuppressLint("MissingPermission") // MANAGE_OWN_CALLS, checked by available()
    fun placeOutgoingCall(context: Context) {
        if (!available(context)) return
        val extras = Bundle().apply { putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle(context)) }
        runCatching {
            context.getSystemService(TelecomManager::class.java)
                .placeCall(Uri.fromParts(PhoneAccount.SCHEME_SIP, "teams", null), extras)
        }.onFailure { Log.w(TAG, "placeCall failed", it) }
    }
}

class TeamsConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(account: PhoneAccountHandle?, request: ConnectionRequest): Connection =
        TeamsConnection().apply {
            setAddress(request.address, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(
                CallController.incoming?.caller ?: getString(R.string.unknown_caller),
                TelecomManager.PRESENTATION_ALLOWED,
            )
            setRinging()
            CallController.attach(this)
        }

    override fun onCreateIncomingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) =
        CallController.onConnectionFailed()

    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest): Connection =
        TeamsConnection().apply {
            setAddress(request.address, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(getString(R.string.teams_call), TelecomManager.PRESENTATION_ALLOWED)
            setDialing()
            CallController.attach(this)
        }

    override fun onCreateOutgoingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) =
        CallController.onConnectionFailed()
}

class TeamsConnection : Connection() {
    var endpoints: List<CallEndpoint> = emptyList()
        private set
    var endpoint: CallEndpoint? = null
        private set

    // Telecom reports its mute state on every audio update, so only act on changes.
    private var systemMuted: Boolean? = null

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD or CAPABILITY_MUTE
        audioModeIsVoip = true
    }

    fun end(cause: Int) {
        setDisconnected(DisconnectCause(cause))
        destroy()
    }

    override fun onShowIncomingCallUi() = CallController.showIncomingUi()

    override fun onAnswer() = CallController.answer(video = false)

    override fun onAnswer(videoState: Int) = CallController.answer(video = VideoProfile.isVideo(videoState))

    override fun onReject() = CallController.decline()

    override fun onDisconnect() = CallController.hangUpFromSystem()

    override fun onAbort() = CallController.hangUpFromSystem()

    override fun onHold() = CallController.hold(true)

    override fun onUnhold() = CallController.hold(false)

    private fun onSystemMute(muted: Boolean) {
        val previous = systemMuted
        systemMuted = muted
        if (previous != null && previous != muted) CallController.setMuted(muted)
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onMuteStateChanged(isMuted: Boolean) = onSystemMute(isMuted)

    @Deprecated("Replaced by CallEndpoint callbacks on API 34")
    override fun onCallAudioStateChanged(state: CallAudioState) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) onSystemMute(state.isMuted)
        CallController.onAudioRouteChanged()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onAvailableCallEndpointsChanged(availableEndpoints: List<CallEndpoint>) {
        endpoints = availableEndpoints
        CallController.onAudioRouteChanged()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onCallEndpointChanged(callEndpoint: CallEndpoint) {
        endpoint = callEndpoint
        CallController.onAudioRouteChanged()
    }
}
