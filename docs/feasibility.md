# Hardware feasibility test

The goal is to decide whether Taptone can ship its core experience with public APIs. Atlas can check menus and permission flow but cannot tell us whether a physical trackpad moved. To run the lab prototype, see the [build instructions](../README.md).

## Checks completed

- Atlas showed the early app off on launch and switching to and from the permission-free demo. Starting capture reached macOS’s `AudioCapture` permission request; with no permission grant and no PCM, the app timed out to an actionable error.
- Taps were felt on a physical Mac in the earlier synthetic demo. That demo used its own beat, so it provided no evidence about alignment with the audio in another app.
- With diagnostics on, the silent demo delivered 37 visual-only cues, with p95 7.2 ms from the detector’s timestamp (end of hop) to the UI event in that run. This is not a live-capture or hardware latency measurement.
- A no-actuation Core Haptics probe on `Mac17,9` (macOS 27.0.1) returned `supportsHaptics=false`. This does not rule out AppKit Force Touch taps or characterize other devices.
- On the physical Mac, all four AppKit diagnostic taps were felt but were too weak. The isolated private probe produced stronger taps and accepted all 20 requests in a controlled granted-capture run. That does not qualify the main app’s AppKit output, establish physical latency, or close the route and restart matrix. See [implementation status](../plans/README.md) for the measured results.

## A. Check trackpad delivery

**Diagnostics → Test Four Taps** waits two seconds, then requests four taps a second apart without starting capture. Run it while idle and rest a fingertip on the pad. Use **Cancel Tap Test** in Diagnostics to stop it. The test uses the same AppKit `.generic` / `.now` request as live mode. **Start Taps** starts live audio capture and tap requests together. Neither mode starts on launch.

Apple documents AppKit haptics for user-initiated feedback; a lab result is not a shipping endorsement. On a physical Mac, play a steady click track with a strong low-frequency kick and rest a fingertip without clicking. Repeat with **Stop Taps** as the no-tap control. AppKit does not report physical delivery. Stop immediately if it’s uncomfortable or interferes with clicking.

| Condition | What to observe |
| --- | --- |
| Taptone is frontmost; fingertip resting | Are taps clear and consistently felt? |
| YouTube is frontmost; Taptone’s menu is closed | Same result without foreground focus? |
| YouTube is frontmost; no trackpad contact | Negative control; AppKit may suppress taps without touch. |
| YouTube is frontmost; mouse was the last-used device, then trackpad contact | Does the default device still behave as expected? |
| Force Click/haptic feedback disabled, if the setting is available | Record behavior without changing or bypassing the preference. |
| Magic Trackpad, if available | Repeat the first two cases over USB and Bluetooth; record results separately. |

Record Mac model, macOS version, trackpad type, preferences, expected taps, felt taps and comfort. For live testing, require at least 80% of requested taps to be felt on the built-in trackpad in the background, without extra pulses or input interference. This is a proposed product threshold, not a platform guarantee. If the test only works in front or while moving a finger, don’t build a product around it. If it passes, we still need a separate decision about shipping given the documented API limitation.

## B. Prove capture independently

The private HAL tap and aggregate device are configured to leave normal audio playing. Use diagnostics to check capture arrival and tap request timestamps separately; no PCM is logged. Start with a local click track, then test YouTube in Safari and Chrome and playback in Music. Test speakers and at least one headphone route. Start from a signed bundle with `NSAudioCaptureUsageDescription` and a stable bundle ID so initial allow, deny and retry behavior can be reproduced.

Pass if permission is requested only after Start, normal audio continues unchanged, browser/Music playback delivers usable buffers, and a denied permission or route change does not leave capture running silently. Stop and Quit must dispose of the I/O callback, aggregate device and tap; run repeated start/stop cycles to catch leaks. On lock, sleep or capture error, stop the pipeline and require explicit restart in the MVP. If a particular source delivers no data, report it as unverified or unsupported; do not add a workaround for protected playback.

## C. Connect the paths and measure responsiveness

Optional local diagnostics: quit any existing instance and run `open .build/Taptone.app --args --diagnostics`, then use `log stream --level info --predicate 'subsystem == "com.theiskaa.taptone"'`. This logs when the tap opens, time until the first PCM buffer, and detector timestamp to UI-event timing, with a flag for whether a tap was requested. It logs no PCM. The detector timestamp is the end of the detection hop; these diagnostics do not by themselves measure audio onset to physical motion.

Generate known click tracks with `swift run -c release TaptoneFixtures`. Start with `kick-120.wav` under `.build/fixtures/`, then test 90/150 BPM, a kick-led song, speech, and silence. Compare audio sample time to haptic submission time on the same clock; aim initially for p95 at or below 50 ms on the click fixture. Separately check perceived alignment on speakers and Bluetooth; submission timestamps do not measure either physical actuator timing or headphone playback latency. Require no pulses on silence after warm-up, no repeated pulses from a held bass tone, and no new submissions after Stop (including work already queued). If the check fails, distinguish late requests, missed accents, and requested taps that macOS suppressed before changing the detector.
