# Handsfree

A macOS menu bar app that controls YouTube, Netflix and Instagram Reels with hand gestures through your webcam. Hand tracking uses Apple's Vision framework, on your Mac. Camera frames are never saved or sent anywhere.

## Gestures

Controls change automatically based on the site in the front window.

| Gesture | YouTube and others | Netflix | Instagram |
|---|---|---|---|
| Tap thumb to index fingertip | Play / pause | Play / pause | Pause |
| Tap thumb to middle fingertip | Scroll down | Skip intro | Next reel |
| Tap thumb to ring fingertip | Scroll up | Next episode | Previous reel |
| Point right | Seek forward | Seek forward | Like |
| Point left | Seek back | Seek back | Save |
| Hold a peace sign | Fullscreen | Fullscreen | Comments |
| Hold thumbs up / down | Volume | Volume | Volume |
| Hold an open palm still | Mute | Mute | Mute |

Gestures only act when the front window is a video site or media player, so they can't type into other apps.

## Build and run

Requires an Apple Silicon Mac with the Xcode Command Line Tools. This runs the gesture tests, then builds the app:

```bash
./build.sh
open build/Handsfree.app
```

Allow the camera when asked, and switch on Handsfree under System Settings → Privacy & Security → Accessibility.

### Keeping the permission across rebuilds

By default the app is signed ad-hoc, and macOS drops its Accessibility permission on every rebuild while still showing it as on. To clear the stale entry:

```bash
tccutil reset Accessibility local.handsfree.app
```

To avoid this, create a self-signed code signing certificate named `Handsfree Local Signing` in your login keychain. `build.sh` uses it automatically if it exists.

## Settings

Timings and allowed sites can be changed in `~/Library/Application Support/Handsfree/config.json`, without a rebuild. The file holds only the values you want to override, and the app reloads it within a second. See `Settings` in [GestureCore.swift](Sources/Core/GestureCore.swift) for every option.

Gesture numbers are logged to `~/Library/Logs/Handsfree/gestures.log` for tuning. The log also records the front window's title, which can include the name of what you're watching. It's cleared each time the app starts.

## Layout

- `Sources/Core/GestureCore.swift`: gesture recognition and per-site controls, with no camera or UI code
- `Sources/App/main.swift`: camera, menu bar, on-screen feedback, and sending keys and clicks
- `Tests/main.swift`: simulated hand movements run through the gesture logic
