package io.github.gangofbeads.openteams

import android.Manifest
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.github.gangofbeads.openteams.call.CallController
import io.github.gangofbeads.openteams.share.ScreenShare

/**
 * The app's one foreground service. Its notification and service types follow
 * the call state: ringing, in call (microphone/camera), sharing the screen
 * (mediaProjection), or just keeping Teams connected in the background.
 */
class TeamsService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        refresh()
        return START_STICKY
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    fun refresh() {
        if (!needed()) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            NotificationManagerCompat.from(this).cancel(CALL_NOTIFICATION_ID)
            stopSelf()
            return
        }
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        val call = CallController.incoming != null || CallController.inCall || ScreenShare.active
        val notification = when {
            CallController.incoming != null -> {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                Notifications.incomingCall(this)
            }
            CallController.inCall || ScreenShare.active -> {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                if (granted(Manifest.permission.RECORD_AUDIO)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (CallController.cameraOn && granted(Manifest.permission.CAMERA)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (ScreenShare.active) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                Notifications.ongoingCall(this)
            }
            else -> Notifications.background(this)
        }
        // Types newer than the device are not in its manifest view: specialUse is 34+, camera/microphone 30+.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) types = types and ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE.inv()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            types = types and (ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA).inv()
        }
        // Calls get their own id: a full-screen intent only fires for a newly posted notification.
        val id = if (call) CALL_NOTIFICATION_ID else NOTIFICATION_ID
        try {
            ServiceCompat.startForeground(this, id, notification, types)
            NotificationManagerCompat.from(this).cancel(if (call) NOTIFICATION_ID else CALL_NOTIFICATION_ID)
        } catch (e: Exception) {
            // Typically a missing while-in-use permission; keep the call notification anyway.
            Log.w(TAG, "startForeground failed", e)
            Notifications.notifyIncomingFallback(this)
        }
        ScreenShare.onForegroundReady(this)
    }

    companion object {
        private const val TAG = "TeamsService"
        const val NOTIFICATION_ID = 1
        const val CALL_NOTIFICATION_ID = 3

        private var instance: TeamsService? = null

        private fun needed() =
            Settings.keepAlive || CallController.incoming != null || CallController.inCall || ScreenShare.active

        /** Brings the service in line with the current state (main thread). */
        fun update(context: Context) {
            instance?.let {
                it.refresh()
                return
            }
            if (!needed()) {
                NotificationManagerCompat.from(context).cancel(CALL_NOTIFICATION_ID)
                return
            }
            try {
                ContextCompat.startForegroundService(context, Intent(context, TeamsService::class.java))
            } catch (e: Exception) {
                // Android 12+ refuses foreground services started from the background.
                Log.w(TAG, "startForegroundService refused", e)
                Notifications.notifyIncomingFallback(context)
            }
        }

        fun quit(context: Context) {
            instance?.let {
                ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_REMOVE)
                it.stopSelf()
            }
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
            NotificationManagerCompat.from(context).cancel(CALL_NOTIFICATION_ID)
        }
    }
}
