# Changelog

Notable changes to Taptone. `scripts/release.sh` publishes a version's section as its release notes and dates its heading.

## [Unreleased]

## [0.1.0] - Unreleased

The first release.

- A menu bar app that plays the bass of whatever's on your Mac through the Force Touch trackpad, while your speakers or headphones keep playing as usual.
- Bass notes become a continuous hum that follows the bass's loudness and vibrates in tune with the note; kicks land as a short, harder thump on top.
- Timing follows the output's reported latency, Bluetooth included, with a manual nudge in 10 ms steps.
- The same strength at any volume, or **Follow volume** to weaken it with the sound. Silence sends nothing to the motor.
- Listens whenever it's open; the menu's switch pauses it. Intensity and kick sensitivity in the menu, and a main window with the bass note, the last 12 seconds, and every setting, including open at login.
- A welcome window that plays four test kicks, and standard taps on each kick when the motor can't be opened.
- Reconnects when the audio output changes, and pauses during sleep and screen lock. No microphone; audio is never saved or uploaded.
- Requires macOS 14.2 or later and a Mac with a Force Touch trackpad.
