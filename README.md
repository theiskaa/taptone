<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img alt="taptone: feel the bass through your trackpad" width="472" src="assets/banner-light.svg">
</picture>

<br/>

<p>
  <a href="https://github.com/theiskaa/taptone/releases"><img alt="Release" src="https://img.shields.io/github/v/release/theiskaa/taptone"></a>
  <a href="#install"><img alt="macOS 14.2+" src="https://img.shields.io/badge/macOS-14.2%2B-39624D"></a>
  <a href="Package.swift"><img alt="Swift 6" src="https://img.shields.io/badge/swift-6-F05138"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://github.com/theiskaa/taptone/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/theiskaa/taptone/total"></a>
</p>

Taptone is a menu bar app that plays the bass of whatever is on your Mac through the Force Touch trackpad. Rest a fingertip on the trackpad and you feel the low end of a song, a film, or a game, in time with what you hear. Your speakers or headphones keep playing as usual.

Bass notes become a continuous hum that follows how loud the bass is and vibrates in tune with the note. Kicks land as a short, harder thump on top. Silence sends nothing to the motor, and neither do macOS alert sounds.

Everything happens on your Mac, as the audio plays. Taptone never records the microphone, and audio is never saved or uploaded.

## Install
```sh
curl -fsSL https://raw.githubusercontent.com/theiskaa/taptone/main/install.sh | sh
```

The script downloads the latest release, checks its SHA-256, its Developer ID signature, and Apple's notarization, then puts Taptone in `/Applications` (or `~/Applications` when that isn't writable) and opens it.

Taptone needs macOS 14.2 or later and a Force Touch trackpad: the one built into a MacBook, or a Magic Trackpad 2 or later.

### Prebuilt app
The app is also available in our [GitHub releases](https://github.com/theiskaa/taptone/releases/latest):

|  File  | Platform | Checksum |
|--------|----------|----------|
| [Taptone-&lt;version&gt;-macos.zip](https://github.com/theiskaa/taptone/releases/latest) | macOS 14.2+, Apple Silicon and Intel | [SHA256SUMS](https://github.com/theiskaa/taptone/releases/latest/download/SHA256SUMS) |

Unzip it and move Taptone to Applications.

### Update
Run the install command again. It updates Taptone in place and keeps its settings and audio permission. Taptone also asks GitHub once a day whether a newer version is out, and its menu says so when one is.

### From source
```sh
git clone https://github.com/theiskaa/taptone.git
cd taptone
make install
```

This needs Xcode 16 or later (or the Swift 6 toolchain). It builds Taptone in release, installs it over an existing copy (or into Applications), and opens it.

> [!TIP]
> With an Apple Development certificate in your keychain, the build is signed with it automatically. Otherwise it is signed ad hoc, and macOS asks for system audio access again after every rebuild, because that permission is tied to the signature. `TAPTONE_SIGN_IDENTITY` picks a certificate.

## Getting started
The first launch opens a welcome window. **Try the motor** plays four kicks, so you know what to feel for. Click **Continue** and allow system audio access when macOS asks; this is needed once. Then play something and rest a fingertip on the trackpad.

Taptone lives in the menu bar and listens whenever it is open. With nothing playing it waits quietly, and it picks up again when audio starts. When the output changes, as when headphones connect, it follows the new one on its own. It pauses during sleep and screen lock, and while an app uses the microphone, as during a call.

Timing follows your output's reported latency, Bluetooth included, so the trackpad lines up with your ears. Volume doesn't change the strength: a quiet app, or the volume turned well down, feels as strong as full volume, unless you turn on **Follow volume**. Muting always stops it.

## The menu
The switch at the top pauses Taptone until you resume it, and ⌃⌥⌘P does the same from any app once **Pause shortcut** is on. Below it, a live row shows the sound on the trackpad and the bass note being played. **Intensity** sets how hard the trackpad plays, and **Kicks** how many drum hits come through. **Pause for 1 Hour** pauses it for a while, and quitting stops it.

**Open Taptone** shows the main window, as does opening Taptone again from Finder or Spotlight: the bass note being played and the last 12 seconds, then every setting.

| Setting | What it does |
| --- | --- |
| **Intensity** | Light, medium, or strong. |
| **Kicks** | Fewer, normal, or more. |
| **Follow volume** | Off: the same strength at any volume. On: haptics get weaker as you turn the sound down. |
| **Try the motor** | Four test kicks, with no audio. |
| **Pause during calls** | On by default. Haptics pause while an app uses the microphone, and pick up again when the call ends. |
| **Ignored apps** | Apps whose sound never reaches the trackpad. Safari and other WebKit browsers can't be told apart, so they can't be ignored. |
| **Haptic delay** | Starts at the output's reported latency. If haptics feel early or late, adjust it 10 ms at a time. |
| **Open at login** | Opens Taptone, listening, when you log in. |
| **Pause shortcut** | ⌃⌥⌘P pauses or resumes from any app. |
| **Check for updates** | Once a day, asks GitHub for the latest version. |

## Troubleshooting
**The menu says "Can't hear system audio" or "Hearing only silence".** Choose **Allow System Audio Access…** in the menu and turn Taptone on under *Screen & System Audio Recording*. If it was turned on for an older build, reset the permission and open Taptone again:

```sh
tccutil reset All com.theiskaa.taptone
```

**Nothing happens on the trackpad.** Check that *Force Click and haptic feedback* is on in Trackpad settings, then play the four test kicks with **Try the motor** in the main window. With the lid closed, Taptone plays on a connected Magic Trackpad.

**Haptics stopped during a call, or with nothing playing.** **Pause during calls** holds haptics while any app uses the microphone, dictation apps included. Turn it off in the main window if that isn't what you want.

**Haptics feel early or late.** Choose **Open Taptone** in the menu and adjust **Haptic delay**, 10 ms at a time.

**Logs.** Quit Taptone, open it again with diagnostics on, then watch what it does:

```sh
open -a Taptone --args --diagnostics
/usr/bin/log stream --level info --predicate 'subsystem == "com.theiskaa.taptone"'
```

## Uninstall
Quit Taptone and move it to the Trash. To also forget its settings and audio permission:

```sh
defaults delete com.theiskaa.taptone
tccutil reset All com.theiskaa.taptone
```

## License
Taptone is MIT-licensed. See [LICENSE](LICENSE).

It drives the trackpad's motor through MultitouchSupport, a private macOS framework. Where that isn't available, it falls back to the standard haptic taps AppKit offers, one per kick.
