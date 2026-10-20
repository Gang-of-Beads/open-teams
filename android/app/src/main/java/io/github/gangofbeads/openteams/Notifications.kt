package io.github.gangofbeads.openteams

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import io.github.gangofbeads.openteams.call.CallActionReceiver
import io.github.gangofbeads.openteams.call.CallController
import io.github.gangofbeads.openteams.call.IncomingCallActivity
import io.github.gangofbeads.openteams.share.ScreenShare
import org.json.JSONObject

object Notifications {
    private const val CHANNEL_MESSAGES = "messages"
    private const val CHANNEL_INCOMING = "incoming_calls"
    private const val CHANNEL_ONGOING = "ongoing_calls"
    private const val CHANNEL_SERVICE = "background"
    private const val MESSAGE_ID = 2

    fun createChannels(context: Context) {
        val ringtone = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channels = listOf(
            NotificationChannel(CHANNEL_MESSAGES, context.getString(R.string.channel_messages), NotificationManager.IMPORTANCE_HIGH),
            NotificationChannel(CHANNEL_INCOMING, context.getString(R.string.channel_incoming_calls), NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), ringtone)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 1000)
            },
            NotificationChannel(CHANNEL_ONGOING, context.getString(R.string.channel_ongoing_calls), NotificationManager.IMPORTANCE_DEFAULT).apply {
                setSound(null, null)
            },
            NotificationChannel(CHANNEL_SERVICE, context.getString(R.string.channel_background), NotificationManager.IMPORTANCE_MIN),
        )
        context.getSystemService(NotificationManager::class.java).createNotificationChannels(channels)
    }

    // Covers the POST_NOTIFICATIONS runtime permission on 13+ and the user's switch everywhere.
    private fun canNotify(context: Context) = NotificationManagerCompat.from(context).areNotificationsEnabled()

    private fun broadcast(context: Context, action: String) = PendingIntent.getBroadcast(
        context, action.hashCode(), Intent(context, CallActionReceiver::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE,
    )

    private fun openApp(context: Context, action: String? = null, requestCode: Int = 0) = PendingIntent.getActivity(
        context,
        requestCode,
        Intent(context, MainActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** A Teams web notification (see the Notification shim in android-preload.js). */
    @SuppressLint("MissingPermission") // canNotify
    fun showMessage(context: Context, options: JSONObject) {
        if (!Settings.messageNotifications || !canNotify(context)) return
        val id = options.optString("notificationId")
        val title = options.optString("title")
        val body = options.optString("body")
        val icon = options.optString("icon").takeIf { it.startsWith("data:image/") }?.let {
            runCatching {
                val bytes = Base64.decode(it.substringAfter(','), Base64.DEFAULT)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }.getOrNull()
        }
        val intent = Intent(context, MainActivity::class.java)
            .setAction(MainActivity.ACTION_NOTIFICATION_CLICKED)
            .putExtra(MainActivity.EXTRA_NOTIFICATION_ID, id)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val notification = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_chat)
            .setColor(ContextCompat.getColor(context, R.color.brand))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setLargeIcon(icon)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(context, id.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE))
            .build()
        // One notification per Teams tag (conversation), so a chat updates in place.
        NotificationManagerCompat.from(context).notify(options.optString("tag").ifBlank { id }, MESSAGE_ID, notification)
    }

    fun incomingCall(context: Context): Notification {
        val incoming = CallController.incoming!!
        val caller = Person.Builder()
            .setName(incoming.caller)
            .setIcon(incoming.avatar?.let(IconCompat::createWithBitmap))
            .setImportant(true)
            .build()
        val fullScreen = PendingIntent.getActivity(
            context, 1,
            Intent(context, IncomingCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL_INCOMING)
            .setSmallIcon(R.drawable.ic_call)
            .setColor(ContextCompat.getColor(context, R.color.brand))
            .setContentTitle(incoming.caller)
            .setContentText(incoming.subtitle)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    caller,
                    broadcast(context, CallActionReceiver.ACTION_DECLINE),
                    openApp(context, MainActivity.ACTION_ANSWER_AUDIO, 2),
                ),
            )
            .addAction(R.drawable.ic_videocam, context.getString(R.string.answer_video), openApp(context, MainActivity.ACTION_ANSWER_VIDEO, 3))
            .setFullScreenIntent(fullScreen, true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .build()
            .apply { flags = flags or Notification.FLAG_INSISTENT } // ring until answered, like a phone call
    }

    fun ongoingCall(context: Context): Notification {
        val person = Person.Builder().setName(context.getString(R.string.teams_call)).setImportant(true).build()
        val builder = NotificationCompat.Builder(context, CHANNEL_ONGOING)
            .setSmallIcon(R.drawable.ic_call)
            .setColor(ContextCompat.getColor(context, R.color.brand))
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(person, broadcast(context, CallActionReceiver.ACTION_HANG_UP)))
            .setContentIntent(openApp(context))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setWhen(CallController.callStartedAt)
            .addAction(
                if (CallController.muted) R.drawable.ic_mic else R.drawable.ic_mic_off,
                context.getString(if (CallController.muted) R.string.unmute else R.string.mute),
                broadcast(context, CallActionReceiver.ACTION_TOGGLE_MUTE),
            )
        if (ScreenShare.active) {
            builder.addAction(R.drawable.ic_stop_screen_share, context.getString(R.string.stop_sharing), broadcast(context, CallActionReceiver.ACTION_STOP_SHARING))
        }
        return builder.build()
    }

    fun background(context: Context): Notification =
        NotificationCompat.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_groups)
            .setContentTitle(context.getString(R.string.background_title))
            .setContentText(context.getString(R.string.background_text))
            .setContentIntent(openApp(context))
            .addAction(R.drawable.ic_close, context.getString(R.string.quit), broadcast(context, CallActionReceiver.ACTION_QUIT))
            .setOngoing(true)
            .build()

    /** When the foreground service cannot start, still ring with a plain notification. */
    @SuppressLint("MissingPermission") // canNotify
    fun notifyIncomingFallback(context: Context) {
        if (CallController.incoming != null && canNotify(context)) {
            NotificationManagerCompat.from(context).notify(TeamsService.CALL_NOTIFICATION_ID, incomingCall(context))
        }
    }
}
