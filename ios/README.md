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

- **Native shell around Teams**: a tab bar for Activity, Chat, Calls and More
  (Teams' other apps) with unread badges, the status bar area in Teams' title
  bar color with light/dark following Teams' theme, a loading screen with
  automatic retry when Teams stalls, and a native error screen with Retry.
  Swipe from the left edge to go back from a chat. The page does not
  rubber-band, controls have no web tap highlight or long-press menu, and the
  previous/next/done bar above the keyboard is gone.
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
- Cookies and site data persist across launches, so you stay signed in.
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
and played through a MediaStream) and the app declares the `audio` background
mode. Routing it through a MediaStream keeps it out of Now Playing, so there
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
- **End and Mute** in the iOS call UI hang up and toggle mute in Teams. Hold
  is not supported (Teams web has no hold). The mute state lives in Teams:
  CallKit's own mute is a system-level microphone mute that WebKit undoes,
  which turned the microphone back on, so it is never applied and the iOS
  mute button does not stay highlighted.

How it works: the app subscribes to Teams' internal command stream
(`commandChangeReportingService`, the same source the desktop app uses in
`app/browser/tools/activityHub.js`) for ringing, connected and disconnected
events, and drives `#hangup-button`, `#microphone-button` and the
incoming-call toast's buttons. Like everything that relies on Teams
internals, this can break when Microsoft changes Teams web.

Audio: Teams' audio, including the microphone, runs in WebKit's GPU process
with its own audio session, so the app never switches its own session to a
call mode (that took the microphone away from WebKit). While a CallKit call is
active, WebKit cannot start its audio from scratch, so a call answered on the
lock screen is handed over: the iOS call stays up until you open the app, then
it ends, Teams accepts, and the connected Teams call shows in CallKit again
(Recents lists it twice).

Reporting incoming calls from the background requires the `voip` background
mode (declared in `Config/Info.plist`; no PushKit is used), otherwise iOS
rejects them. The web notification Teams raises for a ringing call is dropped
while the iOS call UI shows it. Calls depend on the app running in the
background (see above); nothing rings after the app is force-quit. CallKit does not work in the iOS
Simulator; use a device.

## Known limitations

- **Notifications need the app running.** They come from the Teams page
  itself, not a push service, so nothing arrives after the app is force-quit
  or killed by iOS (see above).
- **Answering from the lock screen or in the background connects once you
  open the app.** WebKit only starts the microphone for a visible page, and
  not while a CallKit call holds the audio, so the app accepts in Teams after
  you tap the app button in the iOS call UI. The caller hears ringing until
  then; if they hang up first, the iOS call ends too. iOS also stops the
  camera for backgrounded apps.
- **The Calendar does not load** in the embedded browser ("try the desktop
  version"). Join meetings from the chat or the meeting link instead.
- **No screen sharing.** `getDisplayMedia` is not available in `WKWebView` on
  iOS.
- Microsoft can change Teams web at any time; if it starts rejecting this user
  agent or the embedded browser, the app will stop working.

## Project layout

| Path | Purpose |
| --- | --- |
| `OpenTeams.xcodeproj` | Xcode project (one app target, sources picked up from `OpenTeams/` automatically) |
| `OpenTeams/OpenTeamsApp.swift` | SwiftUI entry point |
| `OpenTeams/TeamsViewController.swift` | Web view setup, navigation, popups, permissions, downloads |
| `OpenTeams/PopupViewController.swift` | Sheet used for `window.open()` popups |
| `OpenTeams/TeamsConfig.swift` | Start URL, user agent and trusted Microsoft hosts |
| `OpenTeams/NotificationBridge.swift` | `window.Notification` shim, iOS notifications, app icon badge |
| `OpenTeams/ShellBridge.swift` | Page script: Teams' app bar state (tabs, badges, back, theme) and actions for the native shell |
| `OpenTeams/LoadingView.swift` | Native loading and error screen |
| `OpenTeams/WKWebView+InputAccessory.swift` | Removes the bar WebKit shows above the keyboard |
| `OpenTeams/CallBridge.swift` | Page script: Teams call events and actions (answer, decline, hang up, mute, ringtone) |
| `OpenTeams/CallManager.swift` | CallKit provider: incoming and ongoing calls, mapped to Teams |
| `OpenTeams/WeakScriptMessageHandler.swift` | Breaks the retain cycle between WebKit and the script message handlers |
| `OpenTeams/CookiePathFixer.swift` | Copies Teams cookies with a relative path to `/` so profile pictures load |
| `OpenTeams/BackgroundKeepAlive.swift` | Inaudible MediaStream tone that keeps the page running in the background without a Now Playing entry |
| `Config/Info.plist` | Keys build settings cannot generate (`UIBackgroundModes`) |
| `Config/Signing.xcconfig` | Signing defaults, includes the optional `Local.xcconfig` |
