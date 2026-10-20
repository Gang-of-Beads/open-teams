package io.github.gangofbeads.openteams.web

import android.content.Intent
import android.net.Uri
import io.github.gangofbeads.openteams.Settings

/** Meeting/chat links, msteams: links and tel: numbers to Teams URLs. */
object DeepLinks {
    // Same pattern as LAUNCHER_ROUTE in app/mainAppWindow/deepLinkRouter.js.
    private val LAUNCHER_ROUTE = Regex("^(/l/[^/?#]+/[^?#]+?)/?(\\?.*)?$")
    private const val EMPTY_CHAT_ROUTE = "/l/chat/0/0"

    fun fromIntent(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return when (data.scheme) {
            "tel" -> callNumberUrl(data.schemeSpecificPart)
            "msteams" -> fromMsTeams(data)
            "https" -> data.takeIf { TeamsHosts.isAppOrigin(it) }?.toString()
            else -> null
        }
    }

    /** `msteams:/l/...` and `msteams://teams.microsoft.com/l/...` to https. */
    fun fromMsTeams(uri: Uri): String {
        val host = uri.host?.takeIf { TeamsHosts.isTeamsHost(it) } ?: Uri.parse(Settings.teamsUrl).host
        return uri.buildUpon().scheme("https").authority(host).build().toString()
    }

    /** A PSTN call through Teams: "4:" is the phone-number MRI prefix Teams uses. */
    fun callNumberUrl(number: String): String? {
        val digits = Uri.decode(number).filterIndexed { i, c -> c.isDigit() || (c == '+' && i == 0) }
        if (digits.isEmpty()) return null
        return "${Settings.teamsOrigin}/l/call/0/0?users=" + Uri.encode("4:$digits")
    }

    /** The in-page route for a launcher link, or null when it needs a full navigation. */
    fun toHashRoute(url: String): String? {
        val uri = Uri.parse(url)
        val fragment = uri.encodedFragment
        val candidate = if (fragment?.startsWith("/") == true) fragment else
            uri.encodedPath.orEmpty() + (uri.encodedQuery?.let { "?$it" } ?: "")
        val match = LAUNCHER_ROUTE.find(candidate) ?: return null
        val route = match.groupValues[1]
        val query = match.groupValues[2]
        if (route == EMPTY_CHAT_ROUTE && !Regex("[?&]users=[^&]").containsMatchIn(query)) return null
        return "#$route$query"
    }

    /** Routes inside the running Teams page when possible (no reload), else loads the URL. */
    fun open(url: String) {
        val view = TeamsWeb.webView ?: return
        val route = toHashRoute(url)
        if (route != null && TeamsWeb.pageReady) {
            TeamsWeb.bridge.emit("open-deep-link", route, url)
        } else {
            view.loadUrl(url)
        }
    }
}
