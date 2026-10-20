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
    /** A Teams menu, dialog or temporarily shown header is open; Back closes it. */
    val overlay: Boolean,
    val name: String,
    val email: String,
    val presence: String,
    val presenceColor: Int?,
    val topColor: Int?,
    val bottomColor: Int?,
    /** The list header's buttons (new chat, filter, ...) for the native top bar. */
    val actions: List<Action>,
) {
    class App(val id: String, val label: String, val selected: Boolean)

    /** [id] is Teams' data-testid, e.g. "...-new-message-button" or "more-icon-btn". */
    class Action(val index: Int, val id: String, val label: String, val viewBox: String, val path: String)

    val selectedApp get() = apps.firstOrNull { it.selected }

    companion object {
        fun parse(json: JSONObject): ShellState {
            val apps = json.optJSONArray("apps")
            val profile = json.optJSONObject("profile") ?: JSONObject()
            val colors = json.optJSONObject("colors") ?: JSONObject()
            val actions = json.optJSONArray("actions")
            return ShellState(
                apps = (0 until (apps?.length() ?: 0)).mapNotNull { i ->
                    apps!!.optJSONObject(i)?.let { App(it.optString("id"), it.optString("label"), it.optBoolean("selected")) }
                },
                detail = json.optBoolean("detail"),
                header = json.optBoolean("header"),
                overlay = json.optBoolean("overlay"),
                name = profile.optString("name"),
                email = profile.optString("email"),
                presence = profile.optString("presence"),
                presenceColor = cssColor(profile.optString("presenceColor")),
                topColor = cssColor(colors.optString("top")),
                bottomColor = cssColor(colors.optString("bottom")),
                actions = (0 until (actions?.length() ?: 0)).mapNotNull { i ->
                    actions!!.optJSONObject(i)?.let {
                        Action(it.optInt("index"), it.optString("id"), it.optString("label"), it.optString("viewBox"), it.optString("path"))
                    }
                },
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
