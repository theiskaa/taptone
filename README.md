# Taptone

**Feel what you hear.** Taptone is an experimental macOS menu bar app that detects kicks and bass attacks in audio already playing on your Mac. The goal is to feel those accents through a Force Touch trackpad without changing your normal audio.

## Run the local prototype

Requires macOS 14.2+ and a Swift 6 toolchain with the macOS SDK. No external dependencies.

```sh
swift test
./scripts/build-app.sh release
open .build/Taptone.app
```

1. Open the fingertip icon in the menu bar and choose **Start Taps**. If macOS asks, grant system audio access.
2. Play music or a video and rest a fingertip on your Force Touch trackpad. Taptone requests taps on detected bass accents. Two marks above the fingertip mean listening is on. **Beat Sensitivity** changes which accents trigger a tap, not motor strength.
3. Choose **Stop Taps** when you’re done. To check strength independently of music, choose **Diagnostics → Test Four Taps** while idle. Rest a fingertip on the trackpad: after two seconds, it requests four single taps, one second apart, without audio capture.

**Show Activity** opens an optional dashboard with the audio level, 12 seconds of signal history, and counts for detected beats and trackpad requests. The two counts are separate because macOS doesn’t report whether a tap was felt. **Preview Demo** lets you see the dashboard with synthetic input, without capture permission or haptics. Opening or closing Activity doesn’t start or stop the live session. The dashboard keeps only a small amount of signal metadata in memory and clears it when you start a new session.

This is a development build, not a release. The app requests fixed AppKit taps. They were felt but reported too weak on the tested Mac, and background delivery and alignment with music are not qualified. A local hardware experiment delivered stronger bass taps on that Mac; it is not included in this repo or the app. Magic Trackpad and Intel compatibility are unverified. The build script uses ad hoc signing by default; set `TAPTONE_SIGN_IDENTITY` to use a locally available signing identity.

Taptone starts off. It only captures while listening; it uses no microphone or screen images and never saves or uploads audio. Stop, output changes, sleep/session inactivity, and Quit invalidate pending cues. The app does not use `nospeaker`’s private APIs.

## Structure

| Path | Responsibility |
| --- | --- |
| `Sources/TaptoneCore` | Bass detector, synthetic kick source, tap-test timing, bounded activity history, and rate checks |
| `Sources/AudioMailbox` | Bounded, preallocated single-producer/single-consumer PCM buffer |
| `Sources/AudioListener` | Native block identity for adding and removing Core Audio listeners |
| `Sources/TaptoneAudio` | Core Audio tap, capture lifecycle, and beat processing |
| `Sources/Taptone` | AppKit menu bar, SwiftUI Activity window, and session-bound trackpad taps |
| `Sources/TaptoneFixtures` | Generated audio, reference onsets, and offline detector scoring |

## Repeatable beat test

Run `swift run -c release TaptoneFixtures` from the repo. It writes generated WAVs, known onset labels, and `metrics.csv` under `.build/fixtures/`. Play `kick-120.wav` to check live capture against a steady kick pattern. The CSV scores the detector offline; it doesn’t measure trackpad strength or playback-to-touch latency.

- [Interface research and design](docs/interface.md)
- [Technical research and MVP decision](docs/research.md)
- [Hardware feasibility test](docs/feasibility.md)
- [Implementation status and next steps](plans/README.md)
