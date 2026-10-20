package io.github.gangofbeads.openteams

import android.app.Application
import io.github.gangofbeads.openteams.call.Telecom

class OpenTeamsApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        Settings.init(this)
        Notifications.createChannels(this)
        Telecom.register(this)
    }

    companion object {
        lateinit var instance: OpenTeamsApp
            private set
    }
}
