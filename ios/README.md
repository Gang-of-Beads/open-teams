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

- Identifies as desktop Safari on macOS (the user agent of Safari 27.0.1),
  because Teams web sends every phone and tablet browser, including iPad
  Safari and Android Edge/Chrome/Firefox, to an "open in the app" page.
  Desktop Chrome, Edge and Firefox user agents also pass, but Safari matches
  the WebKit engine that WKWebView actually runs. The desktop layout is used on
  both iPhone and iPad; it is most usable on iPad or iPhone in landscape.
- Cookies and site data persist across launches, so you stay signed in.
- Sign-in and consent popups open in a sheet inside the app. Links to
  non-Microsoft sites open in Safari; `msteams:`, `mailto:` and `tel:` links
  are handed to the system.
- Camera and microphone are available for calls and meetings after the iOS
  permission prompt.
- Downloaded files are offered through the share sheet (Save to Files,
  AirDrop, open in another app).
- Debug builds can be inspected with Safari > Develop on a Mac.

## Known limitations

- **No notifications.** `WKWebView` does not support the Web Notifications or
  Push APIs, so messages and calls do not alert you while the app is not in
  the foreground.
- **No background calls.** iOS suspends the web view shortly after the app
  leaves the foreground, which ends audio and video in an active meeting.
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
| `Config/Signing.xcconfig` | Signing defaults, includes the optional `Local.xcconfig` |
