package io.github.gangofbeads.openteams

import android.Manifest
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.ImageView
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import io.github.gangofbeads.openteams.call.AudioRoutes
import io.github.gangofbeads.openteams.call.CallActionReceiver
import io.github.gangofbeads.openteams.call.CallController
import io.github.gangofbeads.openteams.call.Telecom
import io.github.gangofbeads.openteams.databinding.ActivityMainBinding
import io.github.gangofbeads.openteams.databinding.DialogJoinBinding
import io.github.gangofbeads.openteams.databinding.SheetMoreBinding
import io.github.gangofbeads.openteams.share.ScreenShare
import io.github.gangofbeads.openteams.web.DeepLinks
import io.github.gangofbeads.openteams.web.TeamsHosts
import io.github.gangofbeads.openteams.web.TeamsWeb
import kotlin.math.max

/**
 * The app shell after the native Teams main screen: Teams web fills the
 * screen, a native bottom bar switches Teams apps, and during a call a
 * native control bar adds phone controls (audio route, screen share).
 */
class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private var webView: WebView? = null
    private var imeVisible = false
    private val navItems = mutableMapOf<String, View>()
    private val callListener: () -> Unit = { render() }

    private var permissionCallbacks = mutableListOf<() -> Unit>()
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val callbacks = permissionCallbacks
        permissionCallbacks = mutableListOf()
        callbacks.forEach { it() }
    }

    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private val fileLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data?.takeIf { result.resultCode == RESULT_OK }
        val uris = data?.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
            ?: listOfNotNull(data?.data)
        fileCallback?.onReceiveValue(uris.toTypedArray().takeIf { it.isNotEmpty() })
        fileCallback = null
    }

    private val screenCaptureLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        ScreenShare.onConsent(it.resultCode, it.data)
    }

    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        if (!TeamsWeb.isSupported()) {
            MaterialAlertDialogBuilder(this)
                .setMessage(R.string.webview_too_old)
                .setPositiveButton(android.R.string.ok) { _, _ -> finish() }
                .setCancelable(false)
                .show()
            return
        }

        setUpInsets()
        setUpBottomBar()
        setUpCallBar()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val view = webView
                when {
                    fullscreenCallback != null -> hideFullscreen()
                    view != null && view.canGoBack() -> view.goBack()
                    else -> moveTaskToBack(true) // keep Teams running, like the native app
                }
            }
        })

        val fresh = TeamsWeb.webView == null
        val link = if (savedInstanceState == null) DeepLinks.fromIntent(intent) else null
        attachWebView(if (fresh) link else null)
        if (savedInstanceState == null && (!fresh || link == null)) handleIntent(intent)

        TeamsWeb.bridge.onActiveAppChanged = { selectNav(it) }
        selectNav(TeamsWeb.bridge.activeApp)
        // Notifications for messages and calls; Bluetooth so WebRTC can route call audio to headsets.
        val startupPermissions = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        requestAndroidPermissions(startupPermissions) {}
        TeamsService.update(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        CallController.addListener(callListener)
        render()
    }

    override fun onStop() {
        CallController.removeListener(callListener)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        // A reload would drop the call, so settings apply once it ends.
        if (Settings.reloadNeeded && !CallController.inCall) {
            Settings.reloadNeeded = false
            TeamsWeb.reconfigure()
            Telecom.register(this)
            TeamsService.update(this)
            setUpBottomBar()
        }
    }

    override fun onDestroy() {
        if (TeamsWeb.bridge.onActiveAppChanged != null && TeamsWeb.host === this) TeamsWeb.bridge.onActiveAppChanged = null
        TeamsWeb.detach(this)
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        TeamsWeb.bridge.emitSystemTheme()
        updateSystemBars()
    }

    // --- WebView hosting -------------------------------------------------------

    private fun attachWebView(initialUrl: String?) {
        val view = TeamsWeb.attach(this, initialUrl)
        binding.webContainer.addView(view, 0, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        webView = view
    }

    /** After a renderer crash TeamsWeb drops the old WebView. */
    fun reattachWebView() = attachWebView(null)

    private fun handleIntent(intent: Intent?) {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        when (intent.action) {
            ACTION_ANSWER_AUDIO -> CallController.answer(video = false)
            ACTION_ANSWER_VIDEO -> CallController.answer(video = true)
            ACTION_NOTIFICATION_CLICKED -> TeamsWeb.bridge.emit("notification-clicked", intent.getStringExtra(EXTRA_NOTIFICATION_ID))
            Intent.ACTION_VIEW, Intent.ACTION_DIAL -> DeepLinks.fromIntent(intent)?.let(DeepLinks::open)
        }
    }

    fun requestAndroidPermissions(permissions: List<String>, then: () -> Unit) {
        val missing = permissions.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return then()
        permissionCallbacks.add(then)
        if (permissionCallbacks.size == 1) permissionLauncher.launch(missing.toTypedArray())
    }

    fun showFileChooser(callback: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams): Boolean {
        fileCallback?.onReceiveValue(null)
        val intent = params.createIntent()
        if (params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        return try {
            fileLauncher.launch(intent)
            fileCallback = callback
            true
        } catch (_: ActivityNotFoundException) {
            fileCallback = null
            false
        }
    }

    fun requestScreenCapture() =
        screenCaptureLauncher.launch(getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())

    fun showFullscreen(view: View, callback: WebChromeClient.CustomViewCallback) {
        binding.fullscreen.addView(view)
        binding.fullscreen.isVisible = true
        fullscreenCallback = callback
        WindowCompat.getInsetsController(window, binding.root).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        render()
    }

    fun hideFullscreen() {
        val callback = fullscreenCallback ?: return
        fullscreenCallback = null
        binding.fullscreen.removeAllViews()
        binding.fullscreen.isVisible = false
        WindowCompat.getInsetsController(window, binding.root).show(WindowInsetsCompat.Type.systemBars())
        callback.onCustomViewHidden()
        render()
    }

    // --- Shell -----------------------------------------------------------------

    private fun setUpInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            imeVisible = insets.isVisible(WindowInsetsCompat.Type.ime())
            binding.content.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = max(bars.bottom, ime.bottom))
            render()
            insets
        }
        updateSystemBars()
    }

    private fun updateSystemBars() {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, binding.root).apply {
            isAppearanceLightStatusBars = !night
            isAppearanceLightNavigationBars = !night
        }
    }

    private class NavItem(val app: String, val label: Int, val icon: Int)

    // The native app's default tab order (assets/default_tabs.json), app ids in android-preload.js.
    private val tabs = listOf(
        NavItem("activity", R.string.nav_activity, R.drawable.ic_notifications),
        NavItem("chat", R.string.nav_chat, R.drawable.ic_chat),
        NavItem("teams", R.string.nav_teams, R.drawable.ic_groups),
        NavItem("calendar", R.string.nav_calendar, R.drawable.ic_calendar_today),
        NavItem("calls", R.string.nav_calls, R.drawable.ic_call),
        NavItem("more", R.string.nav_more, R.drawable.ic_more_horiz),
    )

    private fun setUpBottomBar() {
        binding.bottomNav.removeAllViews()
        navItems.clear()
        if (!Settings.nativeNavigation) return
        for (tab in tabs) {
            val item = LayoutInflater.from(this).inflate(R.layout.nav_item, binding.bottomNav, false)
            item.findViewById<ImageView>(R.id.icon).setImageResource(tab.icon)
            item.findViewById<TextView>(R.id.label).setText(tab.label)
            item.contentDescription = getString(tab.label)
            item.setOnClickListener {
                if (tab.app == "more") {
                    showMoreSheet()
                } else {
                    TeamsWeb.bridge.emit("navigate-app", tab.app)
                    selectNav(tab.app)
                }
            }
            binding.bottomNav.addView(item)
            navItems[tab.app] = item
        }
        selectNav(TeamsWeb.bridge.activeApp)
    }

    private fun selectNav(app: String?) {
        val selected = ContextCompat.getColor(this, R.color.brand)
        val normal = ContextCompat.getColor(this, R.color.nav_inactive)
        navItems.forEach { (key, item) ->
            val color = if (key == app) selected else normal
            item.findViewById<ImageView>(R.id.icon).imageTintList = ColorStateList.valueOf(color)
            item.findViewById<TextView>(R.id.label).setTextColor(color)
            item.isSelected = key == app
        }
    }

    private fun showMoreSheet() {
        val sheet = BottomSheetDialog(this)
        val more = SheetMoreBinding.inflate(layoutInflater)
        sheet.setContentView(more.root)
        more.moreFiles.setOnClickListener {
            sheet.dismiss()
            TeamsWeb.bridge.emit("navigate-app", "files")
        }
        more.moreJoin.setOnClickListener {
            sheet.dismiss()
            showJoinDialog()
        }
        more.moreDial.setOnClickListener {
            sheet.dismiss()
            showDialDialog()
        }
        more.moreReload.setOnClickListener {
            sheet.dismiss()
            webView?.reload()
        }
        more.moreSettings.setOnClickListener {
            sheet.dismiss()
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        sheet.show()
    }

    /** Join by link, or by meeting ID and passcode (Teams' /meet/<id>?p=<passcode> join links). */
    private fun showJoinDialog() {
        val form = DialogJoinBinding.inflate(layoutInflater)
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.join_meeting)
            .setView(form.root)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.join) { _, _ ->
                val input = form.meeting.text.toString().trim()
                val passcode = form.passcode.text.toString().trim()
                val id = input.filter(Char::isDigit)
                when {
                    TeamsHosts.isAppOrigin(Uri.parse(input)) -> DeepLinks.open(input)
                    id.length >= 9 && id.length == input.count { !it.isWhitespace() } ->
                        DeepLinks.open("https://teams.microsoft.com/meet/$id" + if (passcode.isNotEmpty()) "?p=${Uri.encode(passcode)}" else "")
                    else -> Toast.makeText(this, R.string.invalid_meeting, Toast.LENGTH_SHORT).show()
                }
            }
            .show()
    }

    private fun showDialDialog() {
        val form = DialogJoinBinding.inflate(layoutInflater)
        form.meeting.inputType = android.text.InputType.TYPE_CLASS_PHONE
        form.meeting.hint = getString(R.string.phone_number)
        (form.passcode.parent.parent as View).isVisible = false
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.call_number)
            .setView(form.root)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.call) { _, _ ->
                DeepLinks.callNumberUrl(form.meeting.text.toString())?.let(DeepLinks::open)
            }
            .show()
    }

    private fun setUpCallBar() {
        binding.callVideo.setOnClickListener { CallController.control("video") }
        binding.callMic.setOnClickListener { CallController.control("mute") }
        binding.callHand.setOnClickListener { CallController.control("raiseHand") }
        binding.callHangUp.setOnClickListener { CallController.control("hangup") }
        binding.callShare.setOnClickListener {
            if (ScreenShare.active) ScreenShare.stop() else CallController.control("share")
        }
        binding.callAudio.setOnClickListener { anchor ->
            val routes = AudioRoutes.available(this)
            val menu = PopupMenu(this, anchor)
            routes.forEachIndexed { index, route ->
                menu.menu.add(0, index, index, route.label).apply {
                    isCheckable = true
                    isChecked = route.active
                }
            }
            menu.setOnMenuItemClickListener {
                routes[it.itemId].select()
                render()
                true
            }
            menu.show()
        }
    }

    private fun render() {
        if (!::binding.isInitialized) return
        val inCall = CallController.inCall
        val pip = isInPictureInPictureMode
        val fullscreen = fullscreenCallback != null
        binding.callBar.isVisible = inCall && !pip && !imeVisible && !fullscreen
        binding.bottomNav.isVisible = Settings.nativeNavigation && !pip && !imeVisible && !fullscreen

        binding.callMic.setImageResource(if (CallController.muted) R.drawable.ic_mic_off else R.drawable.ic_mic)
        binding.callMic.contentDescription = getString(if (CallController.muted) R.string.unmute else R.string.mute)
        binding.callVideo.setImageResource(if (CallController.cameraOn) R.drawable.ic_videocam else R.drawable.ic_videocam_off)
        binding.callShare.setImageResource(if (ScreenShare.active) R.drawable.ic_stop_screen_share else R.drawable.ic_screen_share)
        binding.callAudio.setImageResource(AudioRoutes.current(this)?.icon ?: R.drawable.ic_volume_up)

        // A call behaves like a phone call: over the lock screen, screen on, volume keys set call volume.
        setShowWhenLocked(inCall)
        if (inCall) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        volumeControlStream = if (inCall) AudioManager.STREAM_VOICE_CALL else AudioManager.USE_DEFAULT_STREAM_TYPE
        runCatching { setPictureInPictureParams(pipParams()) } // throws where PiP is unsupported
    }

    // --- Picture-in-picture during calls ----------------------------------------

    private fun pipAction(icon: Int, title: Int, action: String) = RemoteAction(
        Icon.createWithResource(this, icon),
        getString(title),
        getString(title),
        PendingIntent.getBroadcast(this, action.hashCode(), Intent(this, CallActionReceiver::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE),
    )

    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(3, 4))
            .setActions(
                listOf(
                    if (CallController.muted) pipAction(R.drawable.ic_mic_off, R.string.unmute, CallActionReceiver.ACTION_TOGGLE_MUTE)
                    else pipAction(R.drawable.ic_mic, R.string.mute, CallActionReceiver.ACTION_TOGGLE_MUTE),
                    pipAction(R.drawable.ic_call_end, R.string.hang_up, CallActionReceiver.ACTION_HANG_UP),
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(CallController.inCall)
        return builder.build()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && CallController.inCall) enterPictureInPictureMode(pipParams())
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        render()
    }

    companion object {
        const val ACTION_ANSWER_AUDIO = "io.github.gangofbeads.openteams.ANSWER_AUDIO"
        const val ACTION_ANSWER_VIDEO = "io.github.gangofbeads.openteams.ANSWER_VIDEO"
        const val ACTION_NOTIFICATION_CLICKED = "io.github.gangofbeads.openteams.NOTIFICATION_CLICKED"
        const val EXTRA_NOTIFICATION_ID = "notificationId"

        fun bringToFront(context: Context) {
            runCatching {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
