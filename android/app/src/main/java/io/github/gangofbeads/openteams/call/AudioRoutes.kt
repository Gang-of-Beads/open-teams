package io.github.gangofbeads.openteams.call

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.OutcomeReceiver
import android.telecom.CallAudioState
import android.telecom.CallEndpoint
import android.telecom.CallEndpointException
import io.github.gangofbeads.openteams.R

/** Earpiece / speaker / headset / Bluetooth for the current call, like the native call screen's audio button. */
object AudioRoutes {
    class Route(val label: String, val icon: Int, val active: Boolean, val select: () -> Unit)

    fun current(context: Context): Route? = available(context).firstOrNull { it.active }

    /** Hands routing back to the system after a call where we picked a device without Telecom. */
    fun reset(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) context.getSystemService(AudioManager::class.java).clearCommunicationDevice()
    }

    fun available(context: Context): List<Route> {
        val connection = CallController.connection
        if (connection != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && connection.endpoints.isNotEmpty()) {
            return connection.endpoints.map { endpoint ->
                Route(
                    label = endpoint.endpointName.toString(),
                    icon = endpointIcon(endpoint.endpointType),
                    active = endpoint.identifier == connection.endpoint?.identifier,
                ) {
                    connection.requestCallEndpointChange(
                        endpoint,
                        context.mainExecutor,
                        object : OutcomeReceiver<Void, CallEndpointException> {
                            override fun onResult(result: Void?) = Unit
                        },
                    )
                }
            }
        }
        @Suppress("DEPRECATION")
        val state = connection?.callAudioState
        if (connection != null && state != null) {
            return listOf(
                CallAudioState.ROUTE_EARPIECE to R.string.route_phone,
                CallAudioState.ROUTE_SPEAKER to R.string.route_speaker,
                CallAudioState.ROUTE_WIRED_HEADSET to R.string.route_headset,
                CallAudioState.ROUTE_BLUETOOTH to R.string.route_bluetooth,
            ).filter { (route, _) -> state.supportedRouteMask and route != 0 }.map { (route, label) ->
                @Suppress("DEPRECATION")
                Route(context.getString(label), routeIcon(route), state.route == route) { connection.setAudioRoute(route) }
            }
        }
        val audio = context.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return audio.availableCommunicationDevices.filter { it.type in DEVICE_TYPES }.distinctBy { it.type }.map { device ->
                Route(deviceLabel(context, device), deviceIcon(device.type), audio.communicationDevice?.id == device.id) {
                    audio.setCommunicationDevice(device)
                }
            }
        }
        @Suppress("DEPRECATION")
        val speaker = audio.isSpeakerphoneOn
        @Suppress("DEPRECATION")
        return listOf(
            Route(context.getString(R.string.route_phone), R.drawable.ic_phone_in_talk, !speaker) { audio.isSpeakerphoneOn = false },
            Route(context.getString(R.string.route_speaker), R.drawable.ic_volume_up, speaker) { audio.isSpeakerphoneOn = true },
        )
    }

    private val DEVICE_TYPES = setOf(
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID,
    )

    private fun deviceLabel(context: Context, device: AudioDeviceInfo) = when (device.type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> context.getString(R.string.route_phone)
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> context.getString(R.string.route_speaker)
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET ->
            context.getString(R.string.route_headset)
        else -> device.productName?.toString()?.ifBlank { null } ?: context.getString(R.string.route_bluetooth)
    }

    private fun deviceIcon(type: Int) = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> R.drawable.ic_phone_in_talk
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> R.drawable.ic_volume_up
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET -> R.drawable.ic_headset
        else -> R.drawable.ic_bluetooth
    }

    private fun endpointIcon(type: Int) = when (type) {
        CallEndpoint.TYPE_EARPIECE -> R.drawable.ic_phone_in_talk
        CallEndpoint.TYPE_SPEAKER -> R.drawable.ic_volume_up
        CallEndpoint.TYPE_WIRED_HEADSET -> R.drawable.ic_headset
        else -> R.drawable.ic_bluetooth
    }

    private fun routeIcon(route: Int) = when (route) {
        CallAudioState.ROUTE_EARPIECE -> R.drawable.ic_phone_in_talk
        CallAudioState.ROUTE_SPEAKER -> R.drawable.ic_volume_up
        CallAudioState.ROUTE_WIRED_HEADSET -> R.drawable.ic_headset
        else -> R.drawable.ic_bluetooth
    }
}
