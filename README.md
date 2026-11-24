<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img alt="Taptone: feel the bass through your trackpad" width="460" src="assets/banner-light.svg">
</picture>

<br/>

<p>
  <img alt="macOS 14.2+" src="https://img.shields.io/badge/macOS-14.2%2B-39624D">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

Taptone is a menu bar app that plays the bass of whatever’s on your Mac through the Force Touch trackpad. Rest a fingertip on the trackpad and you feel the low end of a song, a film, or a game, in time with what you hear. Your speakers or headphones keep playing as usual.

## How it feels

- **Bass notes** become a continuous hum that follows how loud the bass is and vibrates in tune with the note.
- **Kicks** land as a short, harder thump on top.
- **Timing** follows your output’s reported latency, Bluetooth included, so the trackpad lines up with your ears.
- **Volume** doesn’t matter: a quiet app, or the volume turned way down, feels as strong as full volume. Turn on **Follow volume** if you’d rather it got weaker with the sound.
- **Silence** sends nothing to the motor.

## Install

Once the first version is released, install it with [Homebrew](https://brew.sh):

```sh
brew install --cask theiskaa/tap/taptone
```

Or download `Taptone-<version>-macos.zip` from [Releases](https://github.com/theiskaa/taptone/releases) and move Taptone to Applications.

### From source

You need macOS 14.2 or later, a Mac with a Force Touch trackpad, and Xcode 16 or later (or the Swift 6 toolchain).

```sh
git clone https://github.com/theiskaa/taptone.git
cd taptone
make install
```

This builds Taptone in release, puts it in `/Applications` (or `~/Applications` if that isn’t writable, or wherever it’s already installed), and opens it. Run it again to update; it replaces a running copy.

> [!TIP]
> If you have an Apple Development certificate in your keychain, the build is signed with it automatically. Otherwise the app is signed ad hoc, and macOS asks for system audio access again after every rebuild, because that permission is tied to the signature. Set `TAPTONE_SIGN_IDENTITY` to choose a certificate.

## Use

<img alt="Taptone app icon" width="72" align="right" src="assets/logo.svg">

1. The first launch opens a welcome window. **Try the motor** plays four kicks, so you know what to feel for. Then click **Continue**.
2. Allow system audio access when macOS asks. This is needed once.
3. Play something and rest a fingertip on the trackpad.

Taptone listens whenever it’s open. The switch at the top of its menu pauses it, and quitting stops it. The menu also sets **Intensity** (how hard the trackpad plays) and **Kicks** (how readily drum hits are picked up).

**Open Taptone** shows the main window: the bass note being played and the last 12 seconds, with all the settings below.

| Setting | What it does |
| --- | --- |
| **Intensity** | Light, medium, or strong. |
| **Kick sensitivity** | Low, normal, or high. |
| **Follow volume** | Off: the same strength at any volume. On: haptics get weaker as you turn the sound down. |
| **Haptic delay** | Starts at the output’s reported latency. If haptics feel early or late, adjust it 10 ms at a time. |
| **Open at login** | Opens Taptone, listening, when you log in. |

With nothing playing, Taptone waits quietly and picks up again when audio starts. When the audio output changes, for example when headphones connect, it reconnects to the new output on its own. It pauses during sleep and screen lock, and picks up again when you’re back. It doesn’t use the microphone, and audio is never saved or uploaded.

## Troubleshooting

**The menu says “Can’t hear system audio”.** Choose **Allow system audio access…** in the menu and turn Taptone on under *Screen & System Audio Recording*. If it was turned on for an older build, reset the permission and open Taptone again:

```sh
tccutil reset All com.theiskaa.taptone
```

**Nothing happens on the trackpad.** Check that *Force Click and haptic feedback* is on in Trackpad settings, then use **Diagnostics → Welcome…** to play the four test kicks. If the motor can’t be opened, Taptone falls back to standard taps on each kick, and the menu says “Standard taps”.

**Haptics feel early or late.** Choose **Open Taptone** in the menu and adjust **Haptic delay**, 10 ms at a time.

**Logs.** `make run` builds a debug app with diagnostics on. Watch it with:

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.theiskaa.taptone"'
```

## Uninstall

```sh
make uninstall              # quit and remove the app
scripts/uninstall.sh --purge  # also forget its settings and audio permission
```
