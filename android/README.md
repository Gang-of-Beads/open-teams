# Open Teams for Android

An Android build of open-teams (Teams for Linux). Like the desktop app, it runs
the Teams web app and reuses open-teams' browser modules. Calls, notifications,
navigation and screen sharing are native Android features.

## Building

Release builds are signed with the key in `keystore/open-teams.jks` (password
`open-teams`, committed on purpose so updates install over each other). Every
release must be signed with that same key; a key change forces an uninstall,
which drops the Teams sign-in.


Requires JDK 17 and the Android SDK (platform 36).

```bash
cd android
echo "sdk.dir=$ANDROID_HOME" > local.properties   # or set ANDROID_HOME
./gradlew assembleDebug                            # app/build/outputs/apk/debug/
node scripts/check-preload.mjs                     # smoke-test the bundled preload
```

`bundleOpenTeamsPreload` (in `app/build.gradle.kts`) wraps the open-teams
modules from `../app/browser/` and `app/src/main/js/android-preload.js` into
the asset `open-teams-preload.js`. Changes to those modules reach the Android
app on the next build.

## How it fits together

| Piece | Desktop (Electron) | Android |
| --- | --- | --- |
| Teams web | `BrowserWindow` | One process-wide `WebView` (`web/TeamsWeb.kt`) that outlives the activity |
| Preload | `app/browser/preload.js` | `android-preload.js`, injected at document start on Teams origins only |
| IPC | `ipcRenderer` ↔ `ipcMain` | An `ipcRenderer` shim ↔ `WebBridge.kt` (a `WebMessageListener` scoped to Teams origins) |
| Call events | `activityHub.js` → `incoming-call-created`, `call-connected`, … | Same modules and channels, handled by `call/CallController.kt` |
| Incoming call | `incomingCallToast` window | Self-managed Telecom call, CallStyle notification, full-screen ringing screen |
| Notifications | `Notification` override in preload | The same stub-and-bridge approach, shown as Android `MessagingStyle` notifications grouped per Teams tag, with the sender's avatar |
| Camera and microphone | Chromium's site permissions | `onPermissionRequest` asks Android (one dialog at a time); `permissions.query()` reports Android's grants; a "Open settings" hint once a permission is permanently denied |
| Screen sharing | `desktopCapturer` | `MediaProjection` frames drawn on a canvas; its `captureStream()` answers `getDisplayMedia()` |

Reused open-teams modules: `activityHub`, `reactHandler`, `tokenCache`,
`speakingIndicator`, `wakeLock`, `disableAutogain`, `emulatePlatform`, `theme`,
`activityManager` and `notificationBridge`.

### IPC channels

The channel names are the ones open-teams already uses (`get-config`,
`incoming-call-created`, `incoming-call-ended`, `call-connected`,
`call-disconnected`, `microphone-state-changed`, `camera-state-changed`,
`incoming-call-action`, `notification-clicked`, `system-theme-changed`, …).
The Android app adds:

| Channel | Direction | Purpose |
| --- | --- | --- |
| `show-notification` | page → app | Notification shim (invoke) |
| `media-permissions` | app → page | Android's camera/microphone grants, for `permissions.query()` |
| `shell-state` / `profile-avatar` | page → app | Teams' pinned apps, selection, list/detail view, open menus, presence, theme colors and the list header's buttons (with their SVG icons) for the native bars |
| `navigate-app` / `shell-action` / `shell-back` | app → page | Native bars drive Teams: open an app by id, search, status, settings, all apps, a list header button (`list:<n>`), back |
| `show-keyboard` | page → app | Teams focused a text box after a native tap; the app focuses the WebView and opens the keyboard |
| `call-control` / `call-control-result` | both | In-call buttons; Teams shortcuts as a fallback |
| `screen-share-start` / `screen-share-stop` / `screen-share-ended` | both | `getDisplayMedia()` |
| `open-deep-link` / `deep-link-fallback` | both | In-page routing as in `deepLinkRouter.js` |
| `download-blob` / `save-file` | both | Saving `blob:` downloads |

## Native Teams app analysis

The official Teams APK (`com.microsoft.teams` 1416/1.0.0.2026183002) was
decompiled with [REA](https://github.com/morluto/rea) (JADX), only to see which
features and UI it has. No code or assets were copied. Icons come from Material
Design Icons (Apache-2.0).

| Native app | Android port |
| --- | --- |
| `TelecomConnectionService`: self-managed connection, hold capability, VoIP audio mode | `call/Telecom.kt` with the same Telecom contract |
| Call foreground services (`phoneCall`, `microphone`) and `ScreenCaptureForegroundService` (`mediaProjection`) | `TeamsService`, whose service types follow the call state |
| `CallingNotificationLandingActivity` with `showWhenLocked` / `turnScreenOn` | `call/IncomingCallActivity` |
| Picture-in-picture on call activities | Auto-enters PiP during calls, with mute and hang-up actions |
| `tel:` alias (VIEW/DIAL/CALL) | `tel:` intent filter → Teams PSTN call (`/l/call/0/0?users=4:<number>`) |
| Deep links on Teams hosts (`/l`, `/meet`) and `msteams:` | Same intent filters, routed in page |
| Bottom bar (`default_tabs.json`): Activity, Chat, Teams, Calendar, Calls, More | Native bottom bar driving the web app's rail by app id |
| Call controls: video, mute, audio route, share, more, red end-call | Native call bar: video, mute, audio route, share, raise hand, end call |
| Ringing screen: decline (`#c4314b`), accept (brand `#5b5fc7`), dark stage (`#252424`) | Same layout and colors |
| Join meeting by ID (`MeetingJoinByCodeActivity`) | "Join a meeting" by link or ID and passcode |

## Known limitations

- Microsoft does not support Teams web on mobile, so the app identifies as
  desktop Chrome. Teams may still change behaviour for WebViews.
- There is no Microsoft push service. Incoming calls only arrive while the
  WebView is alive, which is what "Stay connected in the background" and the
  battery optimization exemption are for.
- The selectors for Teams' app rail and in-call buttons (`#microphone-button`,
  `#hangup-button`, …) depend on Teams' DOM. When they miss, calls fall back to
  Teams' keyboard shortcuts (Ctrl+Shift+M/O/H/K/E). The native call bar reads
  the mute and camera state from those buttons' `data-state`.
- WebView gives the "default" microphone its own `groupId` and no label, so
  Teams would select no microphone and disable its mute button in meetings. The
  preload points "default" at the device Chromium opens for it (wired, USB,
  Bluetooth, else speakerphone). Teams cannot pick a speaker (WebView has no
  `setSinkId`); the native call bar's audio route button does that.
- Teams reports its pre-join screen as a connected call; the app ends the
  native call if that screen closes without joining.
- The native top bar shows the buttons of Teams' list header (new chat,
  filter, more) and of an app's own header (Calls), drawn from Teams' SVG
  icons, and those rows are hidden. Teams' list rows are restyled to phone
  sizes. These depend on Teams' DOM (`h1` in the list pane, `entity-header`).
- Teams unmounts an app's view when another app opens and rebuilds it on the
  way back (about 0.3s for Calls, up to 1.5s for Chat and Activity), and it may
  reopen the tab's last conversation right after showing the list. The tab
  switch goes straight back to the list as soon as that conversation appears,
  and the native bars show the tab's list while it builds.
- Screen sharing sends about 10 JPEG frames per second at 1280 px and has no
  system audio.
- Teams' own in-page ringtone can play alongside the system ringtone.
