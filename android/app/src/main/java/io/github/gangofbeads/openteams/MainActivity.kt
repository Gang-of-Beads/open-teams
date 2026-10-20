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
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
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
import androidx.core.graphics.ColorUtils
import androidx.core.view.GravityCompat
import androidx.core.view.updateLayoutParams
import androidx.drawerlayout.widget.DrawerLayout
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
import io.github.gangofbeads.openteams.web.ShellState
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
    private var bottomInset = 0
    private val navItems = mutableMapOf<String, View>()
    private val callListener: () -> Unit = { render() }

    // One Android permission dialog at a time; Teams can ask for the microphone
    // and the camera in quick succession and neither request may be dropped.
    private class PermissionRequest(val permissions: List<String>, val then: () -> Unit)
    private val permissionQueue = ArrayDeque<PermissionRequest>()
    private var permissionDialogShowing = false
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        permissionDialogShowing = false
        val request = permissionQueue.removeFirstOrNull()
        // Denied with "don't ask again": Android will not show the dialog any more.
        val blocked = results.filter { (permission, granted) ->
            !granted && !shouldShowRequestPermissionRationale(permission) &&
                (permission == Manifest.permission.RECORD_AUDIO || permission == Manifest.permission.CAMERA)
        }.keys
        if (blocked.isNotEmpty()) showPermissionSettingsHint(blocked)
        TeamsWeb.emitMediaPermissions()
        TeamsService.update(this) // the microphone/camera service types need the grant
        request?.then?.invoke()
        processPermissionQueue()
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
        setUpShell()
        setUpCallBar()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val view = webView
                val state = shell
                when {
                    binding.drawer.isDrawerOpen(GravityCompat.START) -> binding.drawer.closeDrawer(GravityCompat.START)
                    fullscreenCallback != null -> hideFullscreen()
                    // Back out of Teams' search/menus, then from a conversation to its list.
                    state != null && (state.header || state.detail) -> TeamsWeb.bridge.emit("shell-back")
                    view != null && !TeamsHosts.isAppOrigin(Uri.parse(view.url ?: "")) && view.canGoBack() -> view.goBack()
                    else -> moveTaskToBack(true) // keep Teams running, like the native app
                }
            }
        })

        val fresh = TeamsWeb.webView == null
        val link = if (savedInstanceState == null) DeepLinks.fromIntent(intent) else null
        attachWebView(if (fresh) link else null)
        if (savedInstanceState == null && (!fresh || link == null)) handleIntent(intent)

        TeamsWeb.bridge.onShellChanged = { render() }
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
        TeamsWeb.emitMediaPermissions() // the user may have changed them in system settings
        // A reload would drop the call, so settings apply once it ends.
        if (Settings.reloadNeeded && !CallController.inCall) {
            Settings.reloadNeeded = false
            TeamsWeb.reconfigure()
            Telecom.register(this)
            TeamsService.update(this)
            render()
        }
    }

    override fun onDestroy() {
        if (TeamsWeb.host === this) TeamsWeb.bridge.onShellChanged = null
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
            // Teams starts the microphone (and camera) as soon as it picks up, so ask first.
            ACTION_ANSWER_AUDIO -> requestAndroidPermissions(listOf(Manifest.permission.RECORD_AUDIO)) {
                CallController.answer(video = false)
            }
            ACTION_ANSWER_VIDEO -> requestAndroidPermissions(listOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA)) {
                CallController.answer(video = true)
            }
            ACTION_NOTIFICATION_CLICKED -> {
                Notifications.clearConversation(intent.getStringExtra(EXTRA_NOTIFICATION_TAG))
                TeamsWeb.bridge.emit("notification-clicked", intent.getStringExtra(EXTRA_NOTIFICATION_ID))
            }
            Intent.ACTION_VIEW, Intent.ACTION_DIAL -> DeepLinks.fromIntent(intent)?.let(DeepLinks::open)
        }
    }

    fun requestAndroidPermissions(permissions: List<String>, then: () -> Unit) {
        permissionQueue.addLast(PermissionRequest(permissions, then))
        processPermissionQueue()
    }

    private fun processPermissionQueue() {
        while (!permissionDialogShowing) {
            val next = permissionQueue.firstOrNull() ?: return
            val missing = next.permissions.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
            if (missing.isEmpty()) {
                permissionQueue.removeFirst()
                next.then()
                continue
            }
            permissionDialogShowing = true
            permissionLauncher.launch(missing.toTypedArray())
        }
    }

    private fun showPermissionSettingsHint(permissions: Set<String>) {
        val message = if (permissions.contains(Manifest.permission.CAMERA) && permissions.contains(Manifest.permission.RECORD_AUDIO)) {
            R.string.permission_blocked_both
        } else if (permissions.contains(Manifest.permission.CAMERA)) {
            R.string.permission_blocked_camera
        } else {
            R.string.permission_blocked_microphone
        }
        MaterialAlertDialogBuilder(this)
            .setMessage(message)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.open_settings) { _, _ ->
                startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            }
            .show()
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
            bottomInset = max(bars.bottom, ime.bottom)
            binding.content.updatePadding(left = bars.left, top = bars.top, right = bars.right)
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

    // --- Native shell over Teams' own: top bar, drawer and bottom bar ------------

    /** Teams' shell state once signed in, when the native shell is enabled. */
    private val shell get() = TeamsWeb.bridge.shellState?.takeIf { Settings.nativeNavigation && it.apps.isNotEmpty() }

    private fun setUpShell() {
        binding.avatarButton.setOnClickListener { binding.drawer.openDrawer(GravityCompat.START) }
        binding.topSearch.setOnClickListener { TeamsWeb.bridge.emit("shell-action", "search") }
        fun drawerItem(view: View, action: () -> Unit) = view.setOnClickListener {
            binding.drawer.closeDrawer(GravityCompat.START)
            action()
        }
        drawerItem(binding.drawerProfile) { TeamsWeb.bridge.emit("shell-action", "status") }
        drawerItem(binding.drawerSetStatus) { TeamsWeb.bridge.emit("shell-action", "status") }
        drawerItem(binding.drawerSearch) { TeamsWeb.bridge.emit("shell-action", "search") }
        drawerItem(binding.drawerAllApps) { TeamsWeb.bridge.emit("shell-action", "apps") }
        drawerItem(binding.drawerTeamsSettings) { TeamsWeb.bridge.emit("shell-action", "settings") }
        drawerItem(binding.drawerJoin) { showJoinDialog() }
        drawerItem(binding.drawerDial) { showDialDialog() }
        drawerItem(binding.drawerReload) { webView?.reload() }
        drawerItem(binding.drawerSettings) { startActivity(Intent(this, SettingsActivity::class.java)) }
    }

    // Icons for Teams' built-in apps by app id; anything else gets a generic app icon.
    private fun appIcon(id: String) = when (id.substringBefore('-')) {
        "14d6962d" -> R.drawable.ic_notifications
        "3b64df9d", "86fcd49b" -> R.drawable.ic_chat
        "2a84919f" -> R.drawable.ic_groups
        "ef56c0de" -> R.drawable.ic_calendar_today
        "20c3440d" -> R.drawable.ic_call
        "5af6a76b" -> R.drawable.ic_folder
        "b5abf2ae" -> R.drawable.ic_auto_awesome
        else -> R.drawable.ic_apps
    }

    private fun isDark(color: Int) = ColorUtils.calculateLuminance(color) < 0.4

    private var renderedApps = ""

    private fun renderShell(state: ShellState) {
        val top = state.topColor ?: ContextCompat.getColor(this, R.color.nav_inactive)
        val bottom = state.bottomColor ?: top
        val dark = isDark(top)
        val onBar = if (dark) Color.WHITE else Color.parseColor("#242424")
        binding.mainFrame.setBackgroundColor(top)
        binding.topBar.setBackgroundColor(top)
        binding.topTitle.text = state.selectedApp?.label.orEmpty()
        binding.topTitle.setTextColor(onBar)
        binding.topSearch.imageTintList = ColorStateList.valueOf(onBar)
        WindowCompat.getInsetsController(window, binding.root).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !isDark(bottom)
        }

        // Avatar with presence, top bar and drawer.
        val avatar = TeamsWeb.bridge.avatar
        val initials = state.name.split(' ', '.').filter { it.isNotBlank() }.take(2).joinToString("") { it.first().uppercase() }
        for ((image, text) in listOf(binding.avatarImage to binding.avatarInitials, binding.drawerAvatar to binding.drawerInitials)) {
            image.setImageBitmap(avatar)
            image.isVisible = avatar != null
            text.text = initials
        }
        for ((dot, ring) in listOf(binding.presenceDot to top, binding.drawerPresence to (state.bottomColor ?: top))) {
            dot.isVisible = state.presenceColor != null
            dot.background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(state.presenceColor ?: Color.GRAY)
                setStroke((2 * resources.displayMetrics.density).toInt(), ring)
            }
        }
        binding.drawerName.text = state.name
        binding.drawerEmail.text = state.email
        binding.drawerStatus.text = state.presence.replaceFirstChar { it.titlecase() }
        binding.avatarButton.contentDescription = getString(R.string.open_drawer)

        // Bottom bar: the user's pinned Teams apps, the rest under "More".
        val key = state.apps.joinToString("|") { it.id + it.label }
        if (key != renderedApps) {
            renderedApps = key
            binding.bottomNav.removeAllViews()
            navItems.clear()
            state.apps.take(MAX_TABS).forEach { app ->
                addNavItem(app.id, app.label, appIcon(app.id)) { TeamsWeb.bridge.emit("navigate-app", app.id) }
            }
            addNavItem(MORE, getString(R.string.nav_more), R.drawable.ic_more_horiz) { showMoreSheet() }
        }
        binding.bottomNav.setBackgroundColor(bottom)
        val selected = ContextCompat.getColor(this, if (isDark(bottom)) R.color.brand_on_dark else R.color.brand_on_light)
        val normal = if (isDark(bottom)) Color.parseColor("#ADADAD") else Color.parseColor("#616161")
        val selectedId = state.selectedApp?.id
        navItems.forEach { (id, item) ->
            val color = if (id == selectedId) selected else normal
            item.findViewById<ImageView>(R.id.icon).imageTintList = ColorStateList.valueOf(color)
            item.findViewById<TextView>(R.id.label).setTextColor(color)
            item.isSelected = id == selectedId
        }
    }

    private fun addNavItem(id: String, label: String, icon: Int, onClick: () -> Unit) {
        val item = LayoutInflater.from(this).inflate(R.layout.nav_item, binding.bottomNav, false)
        item.findViewById<ImageView>(R.id.icon).setImageResource(icon)
        item.findViewById<TextView>(R.id.label).text = label
        item.contentDescription = label
        item.setOnClickListener { onClick() }
        binding.bottomNav.addView(item)
        navItems[id] = item
    }

    private fun showMoreSheet() {
        val state = shell ?: return
        val sheet = BottomSheetDialog(this)
        val more = SheetMoreBinding.inflate(layoutInflater)
        state.apps.drop(MAX_TABS).forEach { app ->
            val row = TextView(this, null, 0, R.style.SheetRow).apply {
                text = app.label
                setCompoundDrawablesRelativeWithIntrinsicBounds(appIcon(app.id), 0, 0, 0)
                setOnClickListener {
                    sheet.dismiss()
                    TeamsWeb.bridge.emit("navigate-app", app.id)
                }
            }
            more.moreApps.addView(row, ViewGroup.LayoutParams.MATCH_PARENT, (56 * resources.displayMetrics.density).toInt())
        }
        more.moreAllApps.setOnClickListener {
            sheet.dismiss()
            TeamsWeb.bridge.emit("shell-action", "apps")
        }
        sheet.setContentView(more.root)
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
        // Like the native app: bars on the lists, none in an open conversation or a call.
        val state = shell
        val bars = state != null && !state.detail && !state.header && !inCall && !pip && !fullscreen
        binding.topBar.isVisible = bars
        binding.bottomNav.isVisible = bars && !imeVisible
        binding.drawer.setDrawerLockMode(if (state != null) DrawerLayout.LOCK_MODE_UNLOCKED else DrawerLayout.LOCK_MODE_LOCKED_CLOSED)
        if (state != null) renderShell(state)
        // The bottom bar runs under the navigation bar; otherwise the content stops above it.
        val barHeight = resources.getDimensionPixelSize(R.dimen.bottom_bar_height)
        binding.bottomNav.updateLayoutParams { height = barHeight + bottomInset }
        binding.bottomNav.updatePadding(bottom = bottomInset)
        binding.content.updatePadding(bottom = if (binding.bottomNav.isVisible) 0 else bottomInset)

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
        private const val MAX_TABS = 5
        private const val MORE = "more"
        const val ACTION_ANSWER_AUDIO = "io.github.gangofbeads.openteams.ANSWER_AUDIO"
        const val ACTION_ANSWER_VIDEO = "io.github.gangofbeads.openteams.ANSWER_VIDEO"
        const val ACTION_NOTIFICATION_CLICKED = "io.github.gangofbeads.openteams.NOTIFICATION_CLICKED"
        const val EXTRA_NOTIFICATION_ID = "notificationId"
        const val EXTRA_NOTIFICATION_TAG = "notificationTag"

        fun bringToFront(context: Context) {
            runCatching {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
