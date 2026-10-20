package io.github.gangofbeads.openteams.web

import android.graphics.Color
import org.json.JSONObject

/** What android-preload.js reports about Teams' own shell (reportShell()). */
class ShellState(
    val apps: List<App>,
    /** A conversation or item is open (Teams shows "Return to list"). */
    val detail: Boolean,
    /** Teams' title bar is showing for its search box or a menu. */
    val header: Boolean,
    val name: String,
    val email: String,
    val presence: String,
    val presenceColor: Int?,
    val topColor: Int?,
    val bottomColor: Int?,
) {
    class App(val id: String, val label: String, val selected: Boolean)

    val selectedApp get() = apps.firstOrNull { it.selected }

    companion object {
        fun parse(json: JSONObject): ShellState {
            val apps = json.optJSONArray("apps")
            val profile = json.optJSONObject("profile") ?: JSONObject()
            val colors = json.optJSONObject("colors") ?: JSONObject()
            return ShellState(
                apps = (0 until (apps?.length() ?: 0)).mapNotNull { i ->
                    apps!!.optJSONObject(i)?.let { App(it.optString("id"), it.optString("label"), it.optBoolean("selected")) }
                },
                detail = json.optBoolean("detail"),
                header = json.optBoolean("header"),
                name = profile.optString("name"),
                email = profile.optString("email"),
                presence = profile.optString("presence"),
                presenceColor = cssColor(profile.optString("presenceColor")),
                topColor = cssColor(colors.optString("top")),
                bottomColor = cssColor(colors.optString("bottom")),
            )
        }

        /** "rgb(r, g, b)" / "rgba(r, g, b, a)" as computed by getComputedStyle. */
        fun cssColor(value: String): Int? {
            val parts = Regex("rgba?\\(([^)]*)\\)").find(value)?.groupValues?.get(1)
                ?.split(',')?.map { it.trim().toFloatOrNull() ?: return null } ?: return null
            if (parts.size < 3) return null
            val alpha = if (parts.size > 3) (parts[3] * 255).toInt() else 255
            return Color.argb(alpha, parts[0].toInt(), parts[1].toInt(), parts[2].toInt())
        }
    }
}
