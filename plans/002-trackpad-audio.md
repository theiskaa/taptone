# 002 — Optional trackpad audio

## What the two modes mean

| Mode | What comes from the trackpad |
| --- | --- |
| **Bass Taps** | The current behavior: discrete tactile taps on bass accents. The rest of the mix doesn’t trigger taps. |
| **Trackpad Audio (Experimental)** | An audible, band-limited rendering of the mix, including melody and voice, if the hardware can reproduce it. This is not a broader beat detector. |

Keep one native **Mode** submenu and the existing Start/Stop position. Default to Bass Taps and off at launch. Selecting a mode never starts capture; if someone changes mode while running, stop and require Start again. The normal audio route is unchanged in either mode. Don’t show a Trackpad Audio option in a build that cannot provide it, and don’t silently fall back to taps.

## What we know

- The normal app calls AppKit for a fixed haptic effect. The public API cannot play a PCM stream, choose actuator frequencies, or set the strength of individual notes. The capture engine already reads PCM; the app receives only scalar level and beat events.
- [`os6/nospeaker`](https://github.com/os6/nospeaker) uses the private `MultitouchSupport` actuator API to synthesize tones, rhythm, and speech from a small set of components. Its own results show a very uneven audible band. It does not demonstrate faithful real-time playback on Taptone’s test Mac.
- Taptone’s private probe demonstrated short bass pulses. It did not establish rendering quality, acceptable duty cycle for continuous playback, safe prolonged use, or support on other devices. No private actuator code belongs in the current public-API-only app.

## Build order and gates

1. **Prove recognizable audio without live capture.** In an isolated local experiment, use short generated references with distinct pitches and rhythms *without bass*, then a clip with both bass and melody. A fixed, conservatively bounded proof should let a physical listener distinguish two patterns from the trackpad alone, without touch if audible playback is the goal. Track whether it is heard or merely felt, whether it interferes with clicking, and whether Stop prevents further submissions. Keep intentional start, hardware restrictions, cancellation, fail-closed behavior, and a hard budget on submitted work. Do not relax the existing probe’s pulse limits to squeeze an audio stream through it.
2. **Prove live rendering separately.** After the offline hardware gate and the [capture lifecycle gate](001-finish-taptone.md#phase-2--make-live-capture-and-stop-predictable), estimate a small set of spectral components on the capture worker and pass bounded frames to the isolated renderer. Do not allocate or call the actuator from the HAL callback. Drop stale frames; do not catch up in a burst. Keep user PCM in memory only, never log or save it, and reuse the explicit Stop and route-failure guards. Test a melody without bass, voice, a mixed track, silence, and a manual Stop while original playback continues. Report software latency separately from perceived sync and driver acceptance separately from audible output.
3. **Decide whether to integrate.** A short proof is not approval for continuous driving. Review comfort, sustained use, input interference, supported hardware, and private-API compatibility before enabling the menu option in a separate experimental build. If the motor cannot render recognizable audio, document the limitation instead of calling a full-band tap detector “Trackpad Audio.”

No installed-app or actuator changes are made by this plan.
