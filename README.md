# Taptone

Taptone is a macOS menu bar app that taps your Force Touch trackpad on bass accents. Your speakers or headphones keep playing normally.

## Run from source

Requires macOS 14.2+, a Force Touch trackpad, and Swift 6 with the macOS SDK.

```sh
./scripts/build-app.sh release
open .build/Taptone.app
```

Click the fingertip icon and choose **Start Taps**. Allow system audio access if prompted, then play something. Choose **Stop Taps** when you’re done.

**Show Activity** shows what Taptone detects. **Diagnostics → Test Four Taps** lets you feel the taps without playing music.

## What to expect

This build uses standard macOS haptics. The taps can be subtle, and sync with music is still being tested. Bass Companion and Trackpad Audio are separate experiments and aren’t included here.

Taptone starts off. It doesn’t use the microphone or save or upload audio.
