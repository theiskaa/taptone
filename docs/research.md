# Taptone: research and MVP decision

Five independent research tracks covered the `nospeaker` source, macOS haptics, capture, signal mapping, and the product. This is the initial desk research: no third-party binary was run or trackpad actuated during that work. See [implementation status](../plans/README.md) for subsequent hardware observations and software timing.

## 1. `nospeaker`: a motor reference, not a live capture pipeline

[`os6/nospeaker` at `e02a121`](https://github.com/os6/nospeaker/tree/e02a121243f3dbddb288fa6520134b0c4a8727c6) is a Swift Terminal demo that makes the trackpad emit **audible** speech and music. It calls `/usr/bin/say` to render a 16 kHz WAV, reads it with `AVAudioFile`, and extracts level, pitch, and formants offline at 10 ms steps. Other segments generate notes and rhythms in code. It uses Core Audio to read output mute/volume state, not to capture currently playing PCM. See [speech analysis](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/nospeaker.swift#L272-L445) and [mute checks](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/nospeaker.swift#L194-L217).

The demo dynamically resolves private `MultitouchSupport` symbols, prefers a built-in trackpad, and passes short sine-tone bursts to the selected actuator. Tone frequency, analysis cadence, and actuation submission rate are three different things: a 4 kHz sine in a burst is not 4,000 actuator API calls per second. Voiced speech submits at the detected pitch period, and the sweep uses roughly 20 ms bursts. The demo clamps level and ignores the actuation call’s return value, so a submitted event is not proof of physical delivery. See [actuator selection and playback](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/nospeaker.swift#L71-L179) and [speech and sweep playback](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/nospeaker.swift#L515-L549).

The reported frequency response was measured with a microphone on one Mac; it is not a tactile comfort or long-session result, and external Magic Trackpad support was not verified there. Taptone should borrow the idea, not the backend at this stage. No code has been copied. If we later reuse source, include Cody Collier’s copyright and the full [MIT license](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/LICENSE).

## 2. Haptics: the feasibility gate

- **AppKit** is the documented trackpad feedback path. [`NSHapticFeedbackManager`](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager) offers three named patterns, with no amplitude, frequency, duration, explicit device selection, or delivery acknowledgment. The [default performer](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/defaultperformer) depends on input device, preferences, and accessibility settings. Reacquire it per request.
- **AppKit isn’t documented for a stream of background beats.** Apple tells apps to [call `perform` only in response to user-initiated actions](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:)) and says Force Touch feedback can be suppressed when the trackpad isn’t being touched. A lab test can answer whether a background request fires; passing it would not turn unattended playback into a supported use.
- **Core Haptics** exposes custom transient and continuous events, but the docs reviewed don’t establish built-in or Magic Trackpad routing. Check [`supportsHaptics`](https://developer.apple.com/documentation/corehaptics/chhapticengine/capabilitiesforhardware()) on physical hardware; even a positive result does not identify the actual output device.
- **Private actuator access** is a potential direction for an explicitly separate experiment, not the default. It would require a new decision about device coverage, driver stability, sustained use, and distribution. The [Mac App Store rules](https://developer.apple.com/app-store/review/guidelines/#software-requirements) require public APIs. Distribution outside the store would not make a private API supported or stable.

**Decision:** Test the supported, user-triggered AppKit behavior and check Core Haptics capabilities first. Keep any automatic pulse experiment as a local lab test. Don’t build a full menu bar product around background AppKit taps until we have both a hardware result and a deliberate decision on the API limitation. A logging/visual-only beat prototype is useful if tactile output is blocked.

## 3. Capture: Core Audio first

[Apple’s Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) documents macOS **14.2+**, `NSAudioCaptureUsageDescription`, and a first-use system audio consent prompt when starting I/O on a tap-backed aggregate device. Use an unmuted global mix tap for the “whatever is playing” MVP. Exclude Taptone’s audio-producing processes if any; do not change normal output routing or volume. Keep the tap and aggregate device private to the process; that visibility setting belongs to a **public** API, unlike `MultitouchSupport`. App-specific groups are possible later, but browser tab isolation is not promised.

[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) can supply audio from macOS 13 with app/display-based filters and a different consent experience. Consider it only if older OS support matters or the tap path is unsuitable. We don’t have evidence that one path is faster. Protected content, browser helper behavior, headphones, route changes, and signed/sandboxed builds all need validation. Don’t try to bypass protection if content isn’t available.

## 4. Mapping: salient onsets, not the waveform

Proposed path: **timestamped PCM → bounded preallocated buffer → onset detector → rate-limited pulse events → selectable sink**. Start with a logging sink. Keep allocation, locks, logging, and UI work outside the audio callback. If a live sink is used, submit on the main thread, drop stale cues instead of replaying them after a stall, and invalidate already queued work on Stop or restart.

Starting tuning hypotheses, **not hardware specifications**:

| Parameter | Initial range |
| --- | --- |
| Causal energy window / hop | 20–30 ms / 5–10 ms |
| Bass band | 45–180 Hz |
| Optional broadband band | 180 Hz–4 kHz; a higher threshold to avoid speech chatter |
| Adaptive baseline | Rolling 1–3 s median and median absolute deviation, with a deviation floor |
| Candidate onset | Positive log-energy jump; start at 3–5 deviations for bass, 5–8 for broadband |
| Quiet gate / minimum cue spacing | Tune gate around −60 to −45 dBFS RMS; space cues by 100–160 ms to start |

Average channel **energies** to avoid cancelling anti-phase stereo. Merge same-onset detections. Reset on discontinuities. Test with generated clicks, silence, sustained bass, anti-phase stereo, and narration with and without music. Score misses and false cues against labeled timestamps. Don’t equate request timing with physical motion.

## 5. Product scope and rollout

The MVP focuses on **feeling accents in audio already playing**, not replacing speakers. [Optional trackpad audio](../plans/002-trackpad-audio.md) is planned as a separate experiment. Start off, ask for permission after an explicit Start, show when listening, and keep Stop one click away. A sensitivity control can alter pulse density; it can’t make AppKit taps stronger. On denial, route failure, lock, sleep, or quit, stop and clear pending cues. No mic, screen images, stored audio, or uploads. Start with a built-in Force Touch trackpad; external, Intel, and older macOS coverage are untested. A signed, notarized direct beta is a possible later route, separate from sandbox and store feasibility.

See [the staged feasibility test](feasibility.md) for the hardware gate, capture checks, and initial timing targets.
