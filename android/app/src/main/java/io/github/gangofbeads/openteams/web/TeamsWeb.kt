package io.github.gangofbeads.openteams.web

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Message
import android.os.SystemClock
import android.security.KeyChain
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.github.gangofbeads.openteams.BuildConfig
import io.github.gangofbeads.openteams.MainActivity
import io.github.gangofbeads.openteams.OpenTeamsApp
import io.github.gangofbeads.openteams.Settings
import kotlin.concurrent.thread

/**
 * Owns the single Teams WebView. It outlives MainActivity (the context is a
 * MutableContextWrapper) so a ringing call still reaches the app after the
 * activity is gone, while TeamsService keeps the process alive.
 */
@SuppressLint("StaticFieldLeak")
object TeamsWeb {
    private const val TAG = "TeamsWeb"
    private const val BRIDGE_NAME = "OpenTeamsNative"

    val bridge = WebBridge()
    var webView: WebView? = null
        private set
    var host: MainActivity? = null
        private set

    /** True once the preload on the current Teams page has said hello. */
    var pageReady = false
        internal set

    private var context: MutableContextWrapper? = null
    private var preloadHandler: ScriptHandler? = null

    fun isSupported() = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) &&
        WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)

    fun attach(activity: MainActivity, initialUrl: String?): WebView {
        host = activity
        val wrapper = context ?: MutableContextWrapper(activity).also { context = it }
        wrapper.baseContext = activity
        val view = webView ?: create(wrapper).also {
            webView = it
            it.loadUrl(initialUrl ?: Settings.teamsUrl)
        }
        (view.parent as? ViewGroup)?.removeView(view)
        return view
    }

    fun detach(activity: MainActivity) {
        if (host !== activity) return
        host = null
        webView?.let { (it.parent as? ViewGroup)?.removeView(it) }
        context?.baseContext = activity.applicationContext
    }

    /** Re-applies settings that are fixed at creation, then reloads Teams. */
    fun reconfigure() {
        val view = webView ?: return
        configure(view)
        pageReady = false
        view.loadUrl(Settings.teamsUrl)
    }

    fun signOut() {
        CookieManager.getInstance().removeAllCookies(null)
        WebStorage.getInstance().deleteAllData()
        webView?.apply {
            clearCache(true)
            clearHistory()
        }
        reconfigure()
    }

    fun destroy() {
        webView?.let {
            (it.parent as? ViewGroup)?.removeView(it)
            it.destroy()
        }
        webView = null
        pageReady = false
    }

    fun emitMediaPermissions() = bridge.emit("media-permissions", Settings.mediaPermissions(OpenTeamsApp.instance))

    /**
     * Teams calling shortcuts (open-teams' teamsControlService.js uses the
     * same), sent as real key events when the in-page button is not found.
     */
    fun sendShortcut(keyCode: Int) {
        val view = webView ?: return
        val meta = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON or KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        val now = SystemClock.uptimeMillis()
        view.requestFocus()
        view.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0, meta))
        view.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, keyCode, 0, meta))
    }

    @SuppressLint("SetJavaScriptEnabled")
    internal fun applyCommonSettings(view: WebView) {
        with(view.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(true)
            allowFileAccess = false
            allowContentAccess = false
            builtInZoomControls = true
            displayZoomControls = false
            // Teams' own width when 0; otherwise a fixed desktop layout width, zoomed to fit.
            useWideViewPort = Settings.viewportWidth > 0
            loadWithOverviewMode = Settings.viewportWidth > 0
        }
        UserAgent.apply(view.context, view.settings)
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
    }

    private fun create(context: Context): WebView {
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        val view = WebView(context)
        view.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
        view.webViewClient = Client()
        view.webChromeClient = ChromeClient()
        view.setDownloadListener(Downloads::onDownload)
        configure(view)
        return view
    }

    private fun configure(view: WebView) {
        applyCommonSettings(view)
        val rules = TeamsHosts.originRules()
        preloadHandler?.remove()
        WebViewCompat.removeWebMessageListener(view, BRIDGE_NAME)
        WebViewCompat.addWebMessageListener(view, BRIDGE_NAME, rules, bridge)
        val script = view.context.assets.open("open-teams-preload.js").bufferedReader().use { it.readText() }
        preloadHandler = WebViewCompat.addDocumentStartJavaScript(view, script, rules)
    }

    private fun recreateAfterCrash() {
        destroy()
        val activity = host
        if (activity != null) {
            activity.reattachWebView()
        } else {
            val wrapper = context ?: return
            wrapper.baseContext = OpenTeamsApp.instance
            webView = create(wrapper).also { it.loadUrl(Settings.teamsUrl) }
        }
    }

    /** Camera and microphone for Teams pages only, asking Android first when needed. */
    private fun onPermissionRequest(request: PermissionRequest) {
        if (!TeamsHosts.isAppOrigin(request.origin)) {
            request.deny()
            return
        }
        val wanted = request.resources.filter {
            it == PermissionRequest.RESOURCE_AUDIO_CAPTURE ||
                it == PermissionRequest.RESOURCE_VIDEO_CAPTURE ||
                it == PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID
        }
        val androidPermissions = wanted.mapNotNull {
            when (it) {
                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> Manifest.permission.RECORD_AUDIO
                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> Manifest.permission.CAMERA
                else -> null
            }
        }
        val app = OpenTeamsApp.instance
        val missing = androidPermissions.filter {
            ContextCompat.checkSelfPermission(app, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            request.grant(wanted.toTypedArray())
            return
        }
        val activity = host
        if (activity == null) {
            request.deny()
            return
        }
        activity.requestAndroidPermissions(missing) {
            val granted = wanted.filter { resource ->
                val permission = when (resource) {
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE -> Manifest.permission.RECORD_AUDIO
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE -> Manifest.permission.CAMERA
                    else -> null
                }
                permission == null || ContextCompat.checkSelfPermission(app, permission) == PackageManager.PERMISSION_GRANTED
            }
            if (granted.isEmpty()) request.deny() else request.grant(granted.toTypedArray())
        }
    }

    private class Client : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            when (request.url.scheme) {
                // Stay in the app for the whole sign-in flow, including federated identity providers.
                "http", "https", "about", "blob", "data", "javascript" -> false
                "msteams" -> {
                    view.loadUrl(DeepLinks.fromMsTeams(request.url))
                    true
                }
                else -> {
                    ExternalLinks.open(view.context, request.url)
                    true
                }
            }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            pageReady = false
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Log.w(TAG, "WebView renderer gone (crash=${detail.didCrash()}), recreating")
            if (view === webView) recreateAfterCrash() else view.destroy()
            return true
        }

        // Certificate-based sign-in (open-teams' clientCertificate module covers the desktop).
        override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
            val activity = host ?: return request.cancel()
            KeyChain.choosePrivateKeyAlias(activity, { alias ->
                if (alias == null) return@choosePrivateKeyAlias request.cancel()
                thread {
                    runCatching {
                        val key = KeyChain.getPrivateKey(activity, alias)
                        val chain = KeyChain.getCertificateChain(activity, alias)
                        request.proceed(key, chain)
                    }.onFailure { request.cancel() }
                }
            }, request.keyTypes, request.principals, request.host, request.port, null)
        }
    }

    private class ChromeClient : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) = TeamsWeb.onPermissionRequest(request)

        override fun onShowFileChooser(
            webView: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: FileChooserParams,
        ): Boolean = host?.showFileChooser(filePathCallback, fileChooserParams) ?: false

        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean =
            host?.let { Popups.open(it, resultMsg) } ?: false

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            host?.showFullscreen(view, callback) ?: callback.onCustomViewHidden()
        }

        override fun onHideCustomView() {
            host?.hideFullscreen()
        }

        // Avoids WebView's grey play-button placeholder on every video tile.
        override fun getDefaultVideoPoster(): Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)

        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            if (BuildConfig.DEBUG) Log.d("TeamsConsole", "${message.messageLevel()}: ${message.message()}")
            return true
        }
    }
}
