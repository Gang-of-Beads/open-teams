package io.github.gangofbeads.openteams.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.TeamsService
import io.github.gangofbeads.openteams.share.ScreenShare
import io.github.gangofbeads.openteams.web.TeamsWeb

/** Notification and picture-in-picture buttons that act without opening the app. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_DECLINE -> CallController.decline()
            ACTION_HANG_UP -> CallController.control("hangup")
            ACTION_TOGGLE_MUTE -> CallController.control("mute")
            ACTION_TOGGLE_VIDEO -> CallController.control("video")
            ACTION_STOP_SHARING -> ScreenShare.stop()
            ACTION_QUIT -> {
                TeamsWeb.host?.finishAndRemoveTask()
                TeamsWeb.destroy()
                TeamsService.quit(OpenTeamsApp.instance)
            }
        }
    }

    companion object {
        const val ACTION_DECLINE = "io.github.gangofbeads.openteams.DECLINE"
        const val ACTION_HANG_UP = "io.github.gangofbeads.openteams.HANG_UP"
        const val ACTION_TOGGLE_MUTE = "io.github.gangofbeads.openteams.TOGGLE_MUTE"
        const val ACTION_TOGGLE_VIDEO = "io.github.gangofbeads.openteams.TOGGLE_VIDEO"
        const val ACTION_STOP_SHARING = "io.github.gangofbeads.openteams.STOP_SHARING"
        const val ACTION_QUIT = "io.github.gangofbeads.openteams.QUIT"
    }
}
