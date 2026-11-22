# 001 — Validate and finish the macOS prototype

**Priority:** P1 · **Effort:** L · **Risk:** hardware behavior is the release gate. See [implementation status](README.md) for the current baseline. Before each phase, record `git status --short --branch` and snapshot any uncommitted in-scope files for review. If an excerpt has drifted, re-read the file and update the plan before editing it.

## Target experience

Open Taptone, select **Start Taps**, and feel salient bass accents from audio already playing on a supported Mac with a Force Touch trackpad. Normal audio is unchanged. **Stop Taps** stops capture and prevents further tap requests. The optional **Activity** window explains what is happening; it never starts or stops a session just by being opened or closed. Keep capture opt-in and off on launch. Use no microphone, screen images, stored user audio, uploads, login item, private actuator API, or additional setup screen.

The goal is *accent feedback*, not waveform reproduction or one tap for every sound. Distinguish three things throughout the implementation: **beat detected**, **tap requested**, and **tap felt**. The app can observe only the first two.

## Current code and evidence

| Component | Current behavior | Relevant code |
| --- | --- | --- |
| Input | Unmuted global Core Audio tap in a private aggregate; stereo Float32 or mono/planar equivalent | `Sources/TaptoneAudio/SystemAudioTap.swift`, `TapMailbox.swift`, `Sources/AudioMailbox/` |
| Timing | HAL host timestamps → bounded handoff → worker drain every 8 ms → MainActor; detector cues are stamped at hop completion. `Session.record` keeps only one pending beat. `Session.sendUpdate` drops stale beats. | `Sources/TaptoneAudio/CaptureEngine.swift` |
| Detection | Causal 20 ms bass-energy windows, 10 ms hops, adaptive baseline and a 140 ms detector spacing | `Sources/TaptoneCore/BeatDetector.swift`, `DemoBeat.swift` |
| Output | Explicit Start, generic AppKit tap, 140 ms request rate limit, and session-ID rejection of queued UI events after Stop | `Sources/TaptoneCore/PulseTiming.swift`, `Sources/Taptone/MenuBarController.swift` |
| Monitoring | Bounded 12-second chart plus separate beat and request totals, both fed by the existing capture path | `Sources/TaptoneCore/ActivityHistory.swift`, `Sources/Taptone/ActivityModel.swift`, `ActivityView.swift` |

Baseline: release builds, 12 tests pass, Atlas verified the preview/dashboard and a no-permission failure path. The current physical test reported barely noticeable taps, even on High, and no convincing alignment with the music. That fails the tactile bar; app-side counters, output route and direction of the timing error were not recorded. High only lowers detection thresholds, not AppKit motor strength. A tap was also felt during the previous synthetic demo, but that did not measure sync. The synthetic preview’s observed detector-to-UI p95 of 7.2 ms is not live end-to-end latency. Core Haptics reported no support on one Mac. AppKit documents user-initiated feedback; automatic background tapping is an experiment even if it works on some machines. Background behavior must be stated as tested, not guaranteed. See [research](../docs/research.md) and [feasibility](../docs/feasibility.md).

## Phase 0 — Run the current build on the physical Mac

**Scope:** No source modifications. Record the date, Mac model, macOS, built-in vs. Magic Trackpad, output route, and observable outcome next to the Phase 0 status in `plans/README.md`.

1. In the user’s own Mac terminal, not Atlas, quit any old instance and run `open .build/Taptone.app` from the repo. Open **Show Activity**, then **Start Taps**. The person handles the one-time audio permission if requested. Play 20–30 seconds of a kick-heavy clip through the built-in speakers with the player frontmost. Rest a fingertip without clicking.
2. Record whether the **level moved**, **Beats detected** increased, **Tap requests** increased, and whether taps were **felt**. If felt, categorize the problem as **consistently late/early**, **missed/extra beats**, or **apparently aligned**. Stop while playback continues; the counters must freeze and no new taps should be felt.
3. Route the failure: no level movement → capture/consent investigation; movement but no beat cues → detector; cues but no requests → timing/rate gate; requests but nothing felt → AppKit/trackpad delivery. Do not change detector sensitivity to fix a capture failure.

**Gate:** Four observed signals, Stop behavior, and route documented. If live audio is not accessible, capture is blocked; Phase 1’s synthetic fixture work can proceed but later phases cannot claim live success.

## Phase 1 — Make timing and detection reproducible, then qualify output

**Scope:** `Package.swift` only if a separate dev-only fixture executable is needed, `scripts/`, `Sources/TaptoneCore/`, `Tests/TaptoneCoreTests/`, and narrow opt-in diagnostics in `CaptureEngine.swift` and `MenuBarController.swift`. The separate local study may also use `experiments/trackpad-probe/` and expose the existing public capture/core library products for that package. No detector tuning, UI redesign, or default logging changes.

1. Add a deterministic fixture runner based on `DemoBeat` (reuse synthesis rather than maintaining two kick generators). Produce 20 labeled kicks each at 90, 120, and 150 BPM, with preroll and trailing silence; include steady bass, anti-phase stereo, and predetermined non-beat transients. Derive onset labels from the generated sample indices, not the detector. Put generated WAVs and labels in an ignored build directory. Only generated audio may be written. Keep analysis runnable with `swift test` and no permission.
2. Share the match policy in test code: one detected event per reference onset, in a window from 10 ms early to 45 ms late. Report misses, extras, precision, recall and p95 detection lag in frames/ms by fixture. Freeze the fixtures before changing the detector. Add a short listening test with non-sensitive music and speech; no user PCM in source or logs.
3. Extend `--diagnostics` only as needed to distinguish sample/hop time, worker receipt, main-queue delivery, and request time. All timing values must use the same host clock or be converted explicitly. Count stale and rate-limited cues separately where observable. Do not log or allocate from the HAL callback or write user audio to disk. If the gap between the source onset and acquisition is not independently known, report only the stage intervals you actually measured.

4. **Isolate strength from timing.** Use a known fixed pulse pattern on the built-in trackpad, explicitly triggered and short-lived, with capture off. Compare the app’s public generic tap and the Mac’s normal click as a tactile reference, noting that the latter is not app-controllable. If the public tap is weak in both foreground and background trials, treat this as an output limitation, not a detector deficiency. AppKit does not offer programmable amplitude. Before changing the live detector, decide whether to retain a subtle public-API mode or allow a separate, opt-in local study of the `nospeaker`-style private actuator path. If approved, cap the study to short bursts with conservative strength, explicit Stop, a duty-cycle limit, no autorestart, and no private API code in the default app. Test it against the same fixed pattern; don’t assume it is stronger on this Mac, stable across macOS, or suitable for distribution. Once a pulse is noticeably stronger, use that exact waveform in an isolated, bounded `--live` run against `kick-120.wav`. Compare the summary with physical timing and comfort, and verify Ctrl-C during a separate playback.

**Gate:** Deterministic timestamps reproduced in two runs; automated fixtures require no permission; baseline records offline detection and live software results separately. `swift test --quiet` passes. For a granted physical run, record input callback arrival and one clean Start/Stop. If no output path meets a plainly noticeable, comfortable tap on a resting finger, park tactile tuning and document the product decision before Phase 3.

## Phase 2 — Make live capture and Stop predictable

**Scope:** `Sources/TaptoneAudio/`, the native listener binding in `Sources/AudioListener/` and `Package.swift`, `Tests/TaptoneAudioTests/`, `Tests/AudioMailboxTests/`, and only lifecycle status/error reporting in the app or standalone probe. Preserve the one-action Start/Stop and the HAL producer’s bounded, preallocated mailbox.

1. Reproduce each observed startup problem before editing. Distinguish no callbacks, callbacks with silence, unsupported format, explicit permission error, output change, and sleep/session loss. A timeout alone is not proof of permission denial. Add a focused injectable capture boundary or clock only if needed to verify a failure deterministically; do not replace the working HAL stack with a generic framework.
2. Exercise failure after each acquired resource and keep reverse-order teardown, including listener removal and I/O stop. Preserve session-ID invalidation before asynchronous cleanup, and prove an old failure or cue cannot mutate a newly started session. Confirm ordinary pause/silence doesn’t trigger accidental restart, buffer loops, or repeat pulses. Require explicit Start after output changes or machine suspension.
3. Verify on a physical Mac with built-in speakers and one headphone route: local fixture, browser audio, and Music with unprotected media; confirm audio plays uninterrupted before, during and after Taptone. Check allow/deny/relaunch on systems where the tester can safely exercise consent. Repeat Start/Stop 10 times. Observe cleanup for taps, aggregates, callbacks and listeners; keep blocking-permission exit separate from ordinary stop timings.

**Gate:** Unit tests cover stale events, failures and restart; successful first buffer and Stop observed in at least one granted speaker run; no further requests after Stop; ordinary teardown finishes within 250 ms on the tested route or is measured and documented as a blocker. Nothing auto-captures on launch/recovery. If an output remains unsupported, mark it unsupported; don’t bypass protection or add a microphone fallback.

## Phase 3 — Tune the detector and timing against evidence

**Scope:** `BeatDetector.swift`, `PulseTiming.swift`, `CaptureEngine.swift`, and their tests. Begin only once a viable tactile output is identified. Don’t add visual settings, tempo prediction, ML, or a second capture backend here.

1. Run the frozen Phase 1 fixtures against the Phase 2 implementation. Fix the largest measured issue first. Tune gate, envelope, or cooldown independently for missed/extra accents; address delayed worker/UI delivery separately from late detector output. If mailbox backlog discards one or more cues, confirm whether it is useful to handle another pending cue or whether it is safer to drop stale ones. Never replay bursts after a stall.
2. Preserve the plain `BeatDetector` value-type API, Float32 storage, mono equivalence, and channel-power calculation for anti-phase stereo. Add regression cases for each observed failure; test at 44.1, 48 and 96 kHz, and verify silence, a held tone, noise/transients and restart separately. If a broadband cue genuinely helps, show precision/recall improvement without increasing speech chatter before including it.
3. Compare release-build timing before and after on identical fixtures. Report frame-labeled offline onset → detection, live tap-clock timestamp → request, and any unknown playback-to-acquisition time separately. Don’t add a global delay slider to hide uncertain measurements. If a tested output route shows a repeatable offset that needs compensation, propose that explicitly with before/after data; don’t silently offset every user’s taps.

**Gate:** At least 95% precision and recall on each steady kick fixture within the frozen window; zero cues on steady silence and no repeated cue on held bass after the initial attack; no regression in the labeled negatives. Target p95 software onset → request at or below 50 ms only for a controlled run with a known onset on the same clock. If only acquisition/hop timing is known, say so. Reject changes that improve the synthetic score but worsen the documented listening test.

## Phase 4 — Qualify perceived sync and hardware delivery

**Scope:** Manual validation and narrow haptic fixes only. Don’t replace AppKit or copy `nospeaker` code without a separate product decision.

1. Repeat the Phase 0 session with a known kick pattern. Test foreground and background, resting and lifted finger, speakers and headphones, and record Mac/OS/trackpad specifics. Do at least three background-contact runs of 20 known kicks on a built-in Force Touch trackpad. Compare expected accents, detected beats, request timestamps, and felt taps. Keep no-contact trials as a negative control, not an expected success.
2. Use a second tester or Mac if available. Compare normal output with deliberately delayed cues only in a diagnostic experiment if needed to validate perceived timing; do not ship the artificial delay. Rate comfort and note interference with clicking or gestures. Separate Bluetooth presentation latency from detector quality. Record Magic Trackpad or Intel as untested until actually verified.
3. If requests are timely but fewer than 80% are felt across the background-contact runs, there are extra unexplained taps, or comfort is poor, stop and decide whether to keep a visual-only mode or continue as an unsupported local experiment. Do not promote the tactile feature to beta just because a call returned. Even passing results do not make automatic AppKit use documented or stable.

**Gate:** Results table for physical delivery, perceived timing, and comfort; at least 80% of requested taps felt in the supported background condition and no interfering extra taps. Note untested routes and limitations explicitly. Passing this gate qualifies only the configurations tested.

## Phase 5 — Polish Activity and qualify a local beta

**Scope:** `Sources/Taptone/ActivityView.swift`, `ActivityModel.swift`, `MenuBarController.swift`, display-only activity data if needed, `App/Info.plist`, `scripts/build-app.sh`, `README.md`, and feasibility documentation. No unrelated visual overhaul or new dependencies.

1. Review the shortest user path: one Start, one Stop, optional **Show Activity**. Show Off, Connecting, Waiting for Sound, Listening, and actionable failure. Keep beats and requests visually distinct; never label a request as a delivered tap. Check preview, idle, silence, live/failure, history after Stop, reopen, and close-with-session-running. Keep the chart bounded and avoid separate HAL or timers solely for the dashboard when scalar readings already exist.
2. Verify the shipped dev/beta bundle at the stated macOS floor when possible and on the current version. Keep its stable bundle identity and `NSAudioCaptureUsageDescription`. Verify the signature and menu-bar launch. If a Developer ID/notarized build is wanted, require the maintainer’s release authorization and signing identity; don’t install credentials, publish, or claim App Store qualification. Ad hoc is fine for local testing.
3. Document exactly what works on tested Macs, one-step launch, what data stays in memory, how to stop, permission recovery, and what a tap request does not prove. Record tests and physical pass/fail instead of a generic “done.”

**Gate:** `swift test --quiet`, `./scripts/build-app.sh release`, and `codesign --verify --strict .build/Taptone.app` all succeed. Atlas screenshots verify user-visible states without granting permissions there. The release candidate has a real-device result for both live capture and feel, or is explicitly labeled experimental/blocked.

## Review checkpoint after every phase

1. **Review scope before correctness.** Compare against the scratch baseline; every changed file must map to a current phase step. Remove speculative wrappers, duplicate state paths, unnecessary dependencies, and leftover debug code. Keep AppKit/MainActor ownership in `Taptone`, HAL ownership in `TaptoneAudio`, and portable logic in `TaptoneCore`. Use small value types and explicit units (`Ns`, `DBFS`) in timing and audio code.
2. **Review edge cases.** Trace Start → callback → worker → UI → tap → Stop, including stale work and partial setup. Verify bounded data/timers and that audio is never recorded or logged. Read and run every new test; check that each fails for the regression it is meant to catch. Treat Atlas as a GUI check, not a substitute for a physical fingertip.
3. **Run and record the gate.** Run `swift test --quiet` after each code phase; release-build/signature checks after any packaging or GUI change. Log commands, observed results, remaining unknowns and whether any blocker needs the tester. Have a separate reviewer inspect risky HAL, threading or DSP changes before calling the phase accepted. If a test or a device check exposes a fault, fix and rerun this phase before touching the next. If hardware/permission is absent, report what is blocked and don’t invent a green result.
4. **Keep publishing explicit.** Use scoped commits and push only when requested; do not upload a release or change permission settings as part of verification. Use Atlas for automated UI checks and let the tester launch the build and handle consent on their own desktop.
