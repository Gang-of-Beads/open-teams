package io.github.gangofbeads.openteams.web

import android.content.Context
import android.webkit.WebSettings
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.github.gangofbeads.openteams.Settings

/**
 * Teams web sends mobile browsers to an "install the app" page, so present the
 * WebView as desktop Chrome of the same engine version, the way open-teams'
 * platform.chromeUserAgent does on Linux.
 */
object UserAgent {
    private fun chromeVersion(context: Context): String =
        Regex("Chrome/([\\d.]+)").find(WebSettings.getDefaultUserAgent(context))?.groupValues?.get(1) ?: "140.0.0.0"

    fun apply(context: Context, settings: WebSettings) {
        val full = chromeVersion(context)
        val major = full.substringBefore('.')
        val platform = if (Settings.windowsIdentity) "Windows NT 10.0; Win64; x64" else "X11; Linux x86_64"
        settings.userAgentString =
            "Mozilla/5.0 ($platform) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36"

        // navigator.userAgentData would otherwise still say "Android WebView" and mobile.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
            val brands = listOf("Chromium" to full, "Google Chrome" to full, "Not=A?Brand" to "24.0.0.0").map { (brand, version) ->
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand(brand)
                    .setMajorVersion(version.substringBefore('.'))
                    .setFullVersion(version)
                    .build()
            }
            WebSettingsCompat.setUserAgentMetadata(
                settings,
                UserAgentMetadata.Builder()
                    .setBrandVersionList(brands)
                    .setFullVersion(full)
                    .setPlatform(if (Settings.windowsIdentity) "Windows" else "Linux")
                    .setPlatformVersion(if (Settings.windowsIdentity) "10.0.0" else "")
                    .setArchitecture("x86")
                    .setBitness(64)
                    .setModel("")
                    .setMobile(false)
                    .build(),
            )
        }
    }
}
