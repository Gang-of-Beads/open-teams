package io.github.gangofbeads.openteams.web

import android.app.Dialog
import android.graphics.Bitmap
import android.net.Uri
import android.os.Message
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import com.google.android.material.appbar.MaterialToolbar
import io.github.gangofbeads.openteams.MainActivity
import io.github.gangofbeads.openteams.R

/**
 * window.open() from Teams. Sign-in and Teams pages open in an in-app window
 * that keeps its opener (auth popups post their result back); anything else
 * goes to the user's browser.
 */
object Popups {
    fun open(activity: MainActivity, resultMsg: Message): Boolean {
        val child = WebView(activity)
        TeamsWeb.applyCommonSettings(child)
        val toolbar = MaterialToolbar(activity).apply {
            setNavigationIcon(R.drawable.ic_close)
            setNavigationContentDescription(R.string.close)
        }
        val layout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            addView(toolbar, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(child, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val dialog = Dialog(activity, R.style.Theme_OpenTeams_Popup).apply {
            setContentView(layout)
            setOnDismissListener { child.destroy() }
        }
        toolbar.setNavigationOnClickListener { dialog.dismiss() }

        var decided = false
        // The first real URL decides where the window goes; about:blank comes first for scripted popups.
        fun route(uri: Uri): Boolean {
            if (decided || uri.scheme == "about") return false
            decided = true
            if (TeamsHosts.isAppOrigin(uri) || TeamsHosts.isAuthHost(uri.host)) {
                dialog.show()
                return false
            }
            ExternalLinks.open(activity, uri)
            dialog.dismiss()
            return true
        }

        child.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (route(request.url)) return true
                if (request.url.scheme == "http" || request.url.scheme == "https") return false
                ExternalLinks.open(activity, request.url)
                return true
            }

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                if (url != null && route(Uri.parse(url))) view.stopLoading()
            }

            override fun onPageFinished(view: WebView, url: String?) {
                toolbar.title = view.title
            }
        }
        child.webChromeClient = object : WebChromeClient() {
            override fun onCloseWindow(window: WebView) = dialog.dismiss()
        }
        (resultMsg.obj as WebView.WebViewTransport).webView = child
        resultMsg.sendToTarget()
        return true
    }
}
