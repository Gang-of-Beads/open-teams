# Open Teams for Android

An Android build of open-teams (Teams for Linux). Like the desktop app, it runs
the Teams web app and reuses open-teams' browser modules. Calls, notifications,
navigation and screen sharing are native Android features.

## Building

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
| Notifications | `Notification` override in preload | The same stub-and-bridge approach, shown as Android notifications |
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
| `navigate-app` / `active-app-changed` | both | Native bottom bar ↔ Teams' app rail |
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
  Teams' keyboard shortcuts (Ctrl+Shift+M/O/H/K/E).
- Screen sharing sends about 10 JPEG frames per second at 1280 px and has no
  system audio.
- Teams' own in-page ringtone can play alongside the system ringtone.
