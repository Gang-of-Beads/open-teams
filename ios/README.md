# Open Teams for iOS

An experimental native iOS and iPadOS wrapper around the Teams web app
(`https://teams.cloud.microsoft`), built with Swift and `WKWebView`.

Electron does not run on iOS, so this is a separate, small app. It does not
share code with the desktop app under `app/`, and none of the desktop features
(tray, MQTT, custom backgrounds, configuration file, and so on) exist here.

> [!WARNING]
> This is an unofficial, experimental build for personal sideloading. It is
> not distributed through the App Store. Microsoft publishes an official Teams
> app for iOS, which is the supported option for most users.

## Requirements

- macOS with Xcode 16 or newer (the project uses file-system synchronized
  groups, so older Xcode versions cannot open it)
- iOS / iPadOS 16.4 or newer
- To install on a physical device: an Apple ID added in Xcode > Settings >
  Accounts. A free Personal Team is enough for your own devices.

## Download a prebuilt ipa

Prebuilt ipas are published on the repository's GitHub Releases page as
"iOS X.Y.Z" pre-releases, each with a SHA-256 checksum. The
[iOS workflow](../.github/workflows/ios.yml) runs only when an `ios-vX.Y.Z`
tag is pushed; pull requests and pushes to `main` do not build the iOS app.

The ipa is unsigned: install it with [SideStore](https://sidestore.io),
AltStore or Sideloadly, which re-sign it with your Apple ID. With a free
Apple ID the app must be refreshed every 7 days, and at most 3 sideloaded
apps (including SideStore itself) can be active at once.

To publish a release:

```bash
git tag ios-v0.1.0
git push origin ios-v0.1.0
```

## Build and run in the simulator

Open `ios/OpenTeams.xcodeproj` in Xcode, pick an iPhone or iPad simulator and
press Run. No signing setup is needed for the simulator.

From the command line:

```bash
cd ios
xcodebuild -project OpenTeams.xcodeproj -scheme OpenTeams \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build

xcrun simctl boot "iPhone 16"   # any available simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/OpenTeams.app
xcrun simctl launch booted io.github.openteams.ios
```

> [!NOTE]
> If the app shows a blank page in the simulator and the logs report
> `web process failed to launch`, the simulator runtime is older than the
> Xcode SDK. Install the matching iOS simulator runtime (Xcode > Settings >
> Components), or run on a device.

## Install on an iPhone or iPad

1. Copy the signing template and fill in your Team ID and a unique bundle
   identifier:

   ```bash
   cd ios
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   `Config/Local.xcconfig` is ignored by git, so your team settings never end
   up in a commit.

2. Connect the device, enable Developer Mode on it (Settings > Privacy &
   Security > Developer Mode), open `OpenTeams.xcodeproj`, select the device
   and press Run.

3. The first launch with a free Personal Team is blocked until you trust the
   developer certificate in Settings > General > VPN & Device Management.

Apps signed with a free Personal Team expire after 7 days and need to be
re-installed from Xcode; a paid Apple Developer Program membership extends
this to one year.

## How it behaves

- **Native shell around Teams**: a tab bar for Activity, Chat, Calendar, Calls
  and More (Teams' other apps) with unread badges, the status bar area in Teams' title
  bar color with light/dark following Teams' theme, a loading screen with
  automatic retry when Teams stalls, and a native error screen with Retry.
  Swipe from the left edge to go back from a chat. The page does not
  rubber-band, controls have no web tap highlight or long-press menu, and the
  previous/next/done bar above the keyboard is gone.
- **Chat tab double-tap**: while Chat is selected, double-tap within 350 ms
  to return from a conversation to the list and locate the next loaded unread
  chat. It scrolls and briefly outlines the row without clicking or marking it
  read; repeated double-taps cycle through loaded unread rows. If none has a
  recognized unread marker, the list scrolls to the top. Virtualized/off-screen
  chats that Teams has not rendered are not searched. This uses explicit unread
  attributes/indicator elements, not message text or font weight, and needs
  verification against the current Teams UI.
- **One tap, one action**: Teams' desktop layout shows hover UI (a row's
  "..." button) on the synthetic hover WebKit sends for a touch, and WebKit
  then drops the click, so rows needed two taps. Finger-generated hover events
  are not delivered to Teams (a real mouse or trackpad still hovers). Where
  WebKit still holds the click for CSS hover/focus changes, a clean single
  tap that got no click within 90 ms is clicked once; a late native click for
  that tap is swallowed. Moves, long presses, text fields and taps that stop a
  coasting list are excluded.
- **No slide on tab switches**: measured on device, Teams slides the Activity
  list in from x=-470 over ~430 ms and the Chat list from far left, dropping
  frames. During a native tab switch only, both list panes appear in place.
  Teams' own list/detail transitions are unchanged. Teams still renders the
  Chat app in one long main-thread task (~400 ms measured with Web Inspector
  attached); that delay is Teams' and is not hidden by an overlay.
- **Tab navigation prioritizes response over custom transitions**: no snapshot
  overlay or DOM/animation-settling delay is added. Every explicit tab tap is
  dispatched; if Teams unmounted the app tile, the app bar is opened and the
  tile is retried for up to 900 ms. A newer tab request cancels older retries.
  Teams' own app-bar button stays hidden (More replaces it). Missing tiles
  do not select More or hide the native bar; the last known app and badges are
  retained while that markup is absent. Only a real other-app selection maps
  to More. Teams' own animations are not globally disabled.
- The selected native tab follows the visible destination: a conversation
  opened from Activity selects Chat, and a visible call screen selects Calls,
  even if Teams' own app tile still says Activity. Markers must be topmost at
  their position: Activity keeps the last conversation mounted beneath its
  list. This changes the native
  selection only, without re-navigating or closing the opened conversation.
  Selecting Activity afterwards returns to the feed. Destination detection
  relies on Teams' chat-header/editor and calling UI markers and needs device
  verification after Teams updates.
- The native startup screen is only shown for explicit loads/retries and web
  process recovery, not ordinary in-session document navigation. Its initial
  stall retry does not run during a call or on sign-in pages.
- Downloaded files open in Quick Look (with its share button); anything it
  cannot preview goes to the share sheet.
- Notifications show the sender's picture as a thumbnail when Teams provides
  one.

- Identifies as Microsoft Edge 145 on Windows. Teams web sends every phone
  and tablet browser, including iPad Safari and Android Edge/Chrome/Firefox,
  to an "open in the app" page, and many tenants use a Conditional Access
  policy that only admits Edge (error 530081 with a Safari user agent). The
  page still runs on WebKit, so Chromium-only features may misbehave. The
  desktop layout is used on both iPhone and iPad; it is most usable on iPad or
  iPhone in landscape.
- Cookies and site data persist across launches, and Microsoft session
  cookies are restored after an app restart (see "Sign-in, cookies and
  memory"), so you stay signed in.
- After a cold start Teams reopens the last conversation; the app returns to
  the Chat list once, unless a notification tap or a touch opened it.
- Sign-in and consent popups open in a sheet inside the app. Links to
  non-Microsoft sites open in Safari; `msteams:`, `mailto:` and `tel:` links
  are handed to the system.
- Camera and microphone are available for calls and meetings after the iOS
  permission prompt.
- Profile pictures: Teams sets its avatar cookie with a relative `Path`,
  which Chromium tolerates but WebKit stores literally and never sends, so
  every avatar request fails with 401. The app copies such Teams cookies to
  `Path=/` whenever the cookie store changes. After the first sign-in,
  avatars appear from the next launch (or after a reload).
- Debug builds can be inspected with Safari > Develop on a Mac.

## Notifications and running in the background

`WKWebView` has no Web Notifications API, so the app injects a replacement
`window.Notification` before Teams loads (the same idea as the desktop app's
`app/browser/preload.js`). Each Teams notification becomes an iOS
notification; tapping it opens the app and runs Teams' own click handler, which
opens the conversation. The unread count from the page title (`(3) Chat |
Microsoft Teams`) is mirrored onto the app icon badge. iOS asks for permission
on first launch; you can change it later in Settings > Notifications > Open
Teams.

iOS normally suspends a web view about a second after the app leaves the
foreground, which would stop Teams and all notifications. To keep it running,
the page plays an inaudible tone (30 Hz at -80 dBFS, generated with Web Audio
at 8 kHz mono and played through a MediaStream) and the app declares the
`audio` background mode. The default 48 kHz stereo graph measured ~390 MB of
extra web process memory on device. Routing it through a MediaStream keeps it out of Now Playing, so there
is no media player on the lock screen or in Control Center. Things to know:

- **Battery**: Teams keeps running in the background, so expect noticeably
  higher battery use than an app that relies on push notifications.
- **Force-quitting stops it.** Swiping the app away in the app switcher ends
  the session; nothing arrives until you open it again. There is no push
  service behind this app.
- The audio session is mixable, so music from other apps keeps playing. A phone
  call, Siri or another app taking exclusive audio can pause the tone; the app
  resumes it as soon as the interruption ends (and checks every 15 seconds).
- The `audio` background mode for inaudible playback is fine for sideloading but
  would not pass App Store review.

## Calls (CallKit)

Teams calls are mirrored into CallKit, so they behave like phone calls:

- **Incoming calls** ring with the full-screen iOS call UI, also on the lock
  screen, following the ring/silent switch and Focus. Teams' own ringtone is
  silenced while iOS rings. Answer and Decline click Teams' own buttons; if
  the caller hangs up or you answer on another device, the iOS call UI goes
  away.
- **Calls and meetings you start or join in Teams** show as an ongoing call:
  status bar / Dynamic Island indicator, Recents, and a cellular call
  interrupts it properly.
- **End and Mute** in the iOS call UI hang up and request the corresponding
  absolute mute state in Teams, never a toggle. Repeated mute requests must
  not unmute the microphone. Hold is not supported (Teams web has no hold).
- **Screen stays awake during a connected WebRTC call.** The app tracks real
  peer connections independently of Teams' React events, with a 15-second
  reconnection grace period. Closing the connections, reloading, or a web
  process crash restores automatic screen locking.
- **Local system-mute events are isolated from Teams**, adapted from the
  desktop `ignoreSystemMute.js`. This only changes the events Teams sees on
  local capture tracks, not `track.enabled`, remote tracks or actual system
  audio permissions. It can also hide genuine capture interruptions from
  Teams' UI; device testing is required.

How it works: the app subscribes to Teams' internal command stream
(`commandChangeReportingService`, the same source the desktop app uses in
`app/browser/tools/activityHub.js`) for ringing, connected and disconnected
events, and drives `#hangup-button`, `#microphone-button` and the
incoming-call toast's buttons. Like everything that relies on Teams
internals, this can break when Microsoft changes Teams web.

Audio: Teams' audio, including the microphone, runs in WebKit's GPU process
with its own audio session, so the app never switches its own session to a
call mode (that took the microphone away from WebKit in earlier testing).
The current candidate waits for CallKit's `didActivate` callback before
asking Teams to accept, even while locked, and keeps the full CallKit call.
It does not wait for the user to open the app or end/recreate the CallKit
call. **Locked-device two-way audio has not yet been verified**; previous
attempts encountered WebKit audio activation errors. An unanswered activation
or connection times out instead of leaving a phantom call.

Reporting incoming calls from the background requires the `voip` background
mode (declared in `Config/Info.plist`; no PushKit is used), otherwise iOS
rejects them. The web notification Teams raises for a ringing call is dropped
while the iOS call UI shows it. Calls depend on the app running in the
background (see above); nothing rings after the app is force-quit. CallKit does not work in the iOS
Simulator; use a device.

## Network and session recovery

Following the desktop connection manager's approach, a healthy page is never
reloaded just because Wi-Fi changes or the phone wakes. Only a failed
main-frame network load is retried when connectivity returns or the app
becomes active. Certificate failures are not treated as transient network
errors.

At most once per hour while online and in the foreground, session maintenance
asks Teams' own auth provider to silently acquire its existing Graph resource
token using its cache/expiry logic. It does not install Electron's token-cache
adapter, force renewal, introduce another OAuth client, export tokens to Swift,
or store credentials. This is a best-effort use of an internal Teams API,
not a verified fix for recurring sign-in prompts: MFA, revoked sessions and
tenant sign-in frequency still require interactive authentication. Long-running
session behaviour needs device verification.

## Sign-in, cookies and memory

Measured on an iPhone 17 Pro with Web Inspector, Instruments and the system
log. Details and figures are in the commit history.

- **Session cookies survive restarts.** Teams' MSAL token cache is encrypted
  with a key in a session cookie (`msal.cache.encryption`). WebKit keeps
  session cookies in memory only, so every full app restart made the cache
  unreadable and Teams asked to sign in again. Session cookies of trusted
  Microsoft hosts are saved to the Keychain (this device only, after first
  unlock) when the app leaves the foreground and restored before Teams
  loads. Entries older than 14 days are dropped; only counts are logged.
- **Allow Cross-Website Tracking.** Teams renews sign-in in a hidden
  `login.microsoftonline.com` frame, where WebKit's tracking prevention
  blocks the Microsoft sign-in cookie (`interaction_required`, "We need you
  to sign in again", and the banner's Sign in does nothing). The app declares
  `NSCrossWebsiteTrackingUsageDescription`; turn the switch on under
  Settings > Open Teams. When Teams shows its sign-in banner, the app explains
  this once and offers Open Settings, then reloads Teams on return.
- **Cookie policy, narrowed to Microsoft.** Teams' media gateway
  (`*.asyncgw.teams.microsoft.com`: custom emoji, images) sets its own cookies
  (`skypetoken_asm`, user-scoped `authtoken_asm`) from cross-site requests,
  which the default `onlyFromMainDocumentDomain` policy rejects, so every
  custom emoji showed a placeholder (HTTP 401). The app accepts cookies
  always and `ThirdPartyCookieFilter` deletes, as soon as WebKit reports them,
  cookies of any domain that is neither a trusted Microsoft host nor a site
  opened as a page (for example a federated sign-in provider). iOS has no
  per-domain policy; a filtered cookie exists only until the store observer
  runs.
- **Web process memory.** Teams' web process sits near the per-process limit
  (jetsam `per-process-limit` kills were observed, mostly when returning to
  the foreground, followed by an automatic reload). Teams alone measured
  ~1.26 GB; the shell's whole-document MutationObserver added ~370 MB and the
  48 kHz keep-alive graph ~390 MB. The shell now polls a few elements every
  500 ms while visible (nothing while hidden) and the keep-alive runs at
  8 kHz mono. The reduction still needs a repeat measurement.
- Debug builds only: `-OTDisable notifications,keepalive,media,calls,shell`
  (or `all`) leaves page scripts out and `-OTLegacy shell,keepalive` selects
  the previous implementations, for memory comparisons without reinstalling.
  Debug builds also log media gateway cookie names, paths and sizes.

## Known limitations

- **Notifications need the app running.** They come from the Teams page
  itself, not a push service, so nothing arrives after the app is force-quit
  or killed by iOS (see above).
- **Lock-screen answering is experimental.** The activation-sequenced answer
  path needs device testing for both directions of audio. iOS also stops
  camera capture for backgrounded apps.
- **Muting in a call may turn itself off again (known issue).** CallKit and
  WebKit both act on the microphone's mute state; this is being worked on.
- **No screen sharing.** `getDisplayMedia` is not available in `WKWebView` on
  iOS.
- Microsoft can change Teams web at any time; if it starts rejecting this user
  agent or the embedded browser, the app will stop working.

## Page scripts

Injected JavaScript lives in the local Swift package at
`PageScripts/Sources/PageScripts/JavaScript/*.js`, not handwritten Swift
multiline strings. Like Rust's `include_str!`, the contents are embedded in
the executable at build time. Swift accesses them through typed names such as
`BundledScript.calls.source`, without runtime file I/O or a bundle lookup.

The package's **EmbedScriptsPlugin** is a SwiftPM Build Tool Plugin. It calls
**EmbedScriptsGenerator** (also Swift), which writes an
`EmbeddedScripts.generated.swift` extension in the plugin work directory.
SwiftPM compiles this alongside the `PageScripts` library, which the app links.
There is no Python dependency or Xcode Run Script build phase, and no remote
package dependencies. Xcode 16+ (Swift 6) is required.

The generator uses raw string delimiters that preserve JavaScript backslashes
and interpolation-like text. Missing or invalid inputs fail the build. The
generated file is never committed, and the original JS files are not bundled
as resources. Declared inputs and outputs support incremental builds; the
plugin and its commands run sandboxed.

Adding a `.js` file in the JavaScript directory automatically adds a generated
constant; expose it through `BundledScript` when the app needs it. No `.pbxproj`
input list or resource membership changes are needed. The generator CLI can be
inspected with `swift run --package-path ios/PageScripts EmbedScriptsGenerator --help`
from the repository root. In Xcode, approve the local plugin if prompted; CI
passes `-skipPackagePluginValidation` to allow this repository-owned plugin to
run without interactive approval. That flag does not disable its sandbox.

Injection timing, frame scope and message handlers remain in the Swift bridge
classes. The app-ID mapping for the shell is still generated by Swift and
prepended before `shell.js`. Short native-to-page action calls remain inline.
The existing `npm run lint` now also checks the standalone script files.

## Project layout

| Path | Purpose |
| --- | --- |
| `OpenTeams.xcodeproj` | Xcode project (one app target, sources picked up from `OpenTeams/` automatically) |
| `OpenTeams/OpenTeamsApp.swift` | SwiftUI entry point |
| `OpenTeams/BundledScript.swift` | Typed accessors for compile-time embedded JavaScript |
| `PageScripts/Package.swift` | Local package: script library, build plugin and Swift generator |
| `PageScripts/Plugins/EmbedScriptsPlugin/` | SwiftPM Build Tool Plugin with incremental input/output declarations |
| `PageScripts/Sources/EmbedScriptsGenerator/` | Host-side Swift JS-to-Swift generator |
| `PageScripts/Sources/PageScripts/JavaScript/*.js` | Notification, call, media, navigation, viewport, session and keep-alive scripts |
| `OpenTeams/TeamsViewController.swift` | Web view setup, navigation, popups, permissions, downloads |
| `OpenTeams/PopupViewController.swift` | Sheet used for `window.open()` popups |
| `OpenTeams/TeamsConfig.swift` | Start URL, user agent and trusted Microsoft hosts |
| `OpenTeams/NotificationBridge.swift` | `window.Notification` shim, iOS notifications, app icon badge |
| `OpenTeams/ShellBridge.swift` | Page script: Teams' app bar state (tabs, badges, back, theme) and actions for the native shell |
| `OpenTeams/LoadingView.swift` | Native loading and error screen |
| `OpenTeams/WKWebView+InputAccessory.swift` | Removes the bar WebKit shows above the keyboard |
| `OpenTeams/CallBridge.swift` | Page script: Teams call events and actions (answer, decline, hang up, mute, ringtone) |
| `OpenTeams/CallManager.swift` | CallKit provider: incoming and ongoing calls, mapped to Teams |
| `OpenTeams/MediaBridge.swift` | Local capture mute-event isolation and WebRTC call activity |
| `OpenTeams/SessionMaintenance.swift` | Network-failure recovery and Teams-owned silent session maintenance |
| `OpenTeams/WeakScriptMessageHandler.swift` | Breaks the retain cycle between WebKit and the script message handlers |
| `OpenTeams/CookiePathFixer.swift` | Copies Teams cookies with a relative path to `/` so profile pictures load |
| `OpenTeams/SessionCookiePersistence.swift` | Saves Microsoft session cookies to the Keychain and restores them at launch |
| `OpenTeams/ThirdPartyCookieFilter.swift` | Keeps cookies only for Microsoft hosts and sites opened as pages |
| `OpenTeams/BackgroundKeepAlive.swift` | Inaudible MediaStream tone that keeps the page running in the background without a Now Playing entry |
| `Config/Info.plist` | Keys build settings cannot generate (`UIBackgroundModes`) |
| `Config/Signing.xcconfig` | Signing defaults, includes the optional `Local.xcconfig` |
