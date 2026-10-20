package io.github.gangofbeads.openteams

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.preference.PreferenceManager
import org.json.JSONObject

object Settings {
    const val DEFAULT_URL = "https://teams.cloud.microsoft"

    private lateinit var prefs: SharedPreferences

    /** Set when a preference that needs a page reload changes; MainActivity reloads on resume. */
    @Volatile
    var reloadNeeded = false

    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> reloadNeeded = true }

    fun init(context: Context) {
        prefs = PreferenceManager.getDefaultSharedPreferences(context)
        PreferenceManager.setDefaultValues(context, R.xml.preferences, false)
        prefs.registerOnSharedPreferenceChangeListener(listener)
    }

    val teamsUrl: String
        get() {
            val custom = prefs.getString("custom_teams_url", null)?.trim().orEmpty()
            if (custom.startsWith("https://")) return custom
            return prefs.getString("teams_url", DEFAULT_URL) ?: DEFAULT_URL
        }

    val teamsOrigin: String
        get() = Uri.parse(teamsUrl).let { "${it.scheme}://${it.authority}" }

    val windowsIdentity get() = prefs.getString("browser_identity", "linux") == "windows"
    val viewportWidth get() = prefs.getString("viewport_width", "0")?.toIntOrNull() ?: 0
    val nativeNavigation get() = prefs.getBoolean("native_navigation", true)
    val keepAlive get() = prefs.getBoolean("keep_alive", true)
    val telecom get() = prefs.getBoolean("telecom", true)
    val messageNotifications get() = prefs.getBoolean("message_notifications", true)

    /**
     * The open-teams config subset the bundled browser modules read, with the
     * names and defaults of app/config/options.js, plus the Android-only keys
     * android-preload.js reads.
     */
    fun webConfig(): JSONObject = JSONObject()
        .put("followSystemTheme", prefs.getBoolean("follow_system_theme", true))
        .put("emulateWinChromiumPlatform", windowsIdentity)
        .put("awayOnSystemIdle", false)
        .put("appActiveCheckInterval", 2)
        .put("appIdleTimeoutCheckInterval", 10)
        .put(
            "media",
            JSONObject().put(
                "microphone",
                JSONObject()
                    .put("disableAutogain", prefs.getBoolean("disable_autogain", false))
                    .put("speakingIndicator", prefs.getBoolean("speaking_indicator", false)),
            ),
        )
        .put(
            "android",
            JSONObject()
                .put("viewportWidth", viewportWidth)
                .put("nativeNavigation", nativeNavigation),
        )
}
