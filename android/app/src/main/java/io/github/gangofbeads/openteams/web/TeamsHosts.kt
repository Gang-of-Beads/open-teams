package io.github.gangofbeads.openteams.web

import android.net.Uri
import io.github.gangofbeads.openteams.Settings

/** Kotlin port of app/helpers/teamsHosts.js, plus the hosts Teams sign-in uses. */
object TeamsHosts {
    private val TEAMS_HOSTS = listOf("teams.cloud.microsoft", "teams.microsoft.com", "teams.live.com")
    private const val MCAS_SUFFIX = ".mcas.ms"

    /** Sign-in hosts whose popups must stay in the app (they post back to their opener). */
    private val AUTH_HOSTS = listOf(
        "login.microsoftonline.com", "login.microsoft.com", "login.live.com",
        "login.windows.net", "account.live.com", "microsoftonline.com",
    )

    fun isTeamsHost(host: String?): Boolean {
        var name = host?.lowercase() ?: return false
        if (name.endsWith(MCAS_SUFFIX)) name = name.removeSuffix(MCAS_SUFFIX)
        return TEAMS_HOSTS.any { domain ->
            name == domain || (name.endsWith(".$domain") && !name.removeSuffix(".$domain").contains('.'))
        }
    }

    /** Teams origins plus the configured URL's origin (GovCloud and other overrides). */
    fun isAppOrigin(uri: Uri?): Boolean {
        if (uri?.scheme != "https") return false
        return isTeamsHost(uri.host) || uri.host == Uri.parse(Settings.teamsUrl).host
    }

    fun isAuthHost(host: String?): Boolean {
        val name = host?.lowercase() ?: return false
        return AUTH_HOSTS.any { name == it || name.endsWith(".$it") }
    }

    /** Origin rules for the document-start script and the native bridge. */
    fun originRules(): Set<String> =
        TEAMS_HOSTS.flatMap { listOf("https://$it", "https://*.$it") }.toSet() + Settings.teamsOrigin
}
