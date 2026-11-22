# Taptone Trackpad Probe

This standalone macOS command compares a fixed private-actuator pulse with Taptone’s public AppKit tap, then lets you test the firmer pulse against live bass accents. Only explicit `--live` mode uses system audio. Nothing in this package runs as part of `Taptone.app`; it is not a release component.

From the Taptone repo:

```sh
./scripts/build-trackpad-probe.sh
.build/trackpad-probe/TaptoneTrackpadProbe --check
```

`--check` resolves the required private symbols without opening a device. `--dry-run` prints the schedule and does not load the framework. Omitting arguments is also a dry run.

## Physical check

Quit Taptone or stop its taps. From your Mac’s own foreground terminal, run:

```sh
.build/trackpad-probe/TaptoneTrackpadProbe --run
```

Rest one fingertip on the built-in trackpad. After two seconds, it requests **two gentle pulses**, then **two firmer pulses**, spaced one second apart. Compare them with the four AppKit taps you already tried. Note which pair you could feel more clearly, whether it was comfortable, and whether you mostly heard it instead of feeling it. Press **Ctrl-C** if uncomfortable. The probe checks for cancellation during waits and immediately before asking the driver to play. A pulse already submitted cannot be recalled; its nominal duration is 20 ms.

The one-shot program uses 200 Hz, 20 ms pulses, and fixed command levels 0.20 and 0.40. These are inputs to an undocumented API, not measured motor force or a safety certification. In `--run` mode there are no arbitrary strength, repeat, external-device, or live-audio options. The probe stops on driver errors instead of retrying them. Its six-second deadline is cooperative: a synchronous driver call can outlast it, but requests are checked again before proceeding. If anything feels wrong or clicking behavior changes, stop and don’t repeat it.

## Live timing check on the physical Mac

Use the built-in speakers and built-in trackpad for the first run. Stop Taptone’s taps and pause other audio. The generated 12-second fixture has 20 kicks spaced half a second apart.

From the repo, generate the clip if needed: `swift run -c release TaptoneFixtures`. Paste both lines into your Mac’s interactive terminal, not into a script. The player is a separate background job; the probe stays in the foreground.

```sh
(sleep 2; afplay .build/fixtures/kick-120.wav) &
.build/trackpad-probe/TaptoneTrackpadProbe --live
```

1. If macOS asks for system audio access, handle the prompt and rerun the two lines once the first playback ends. The probe alone does not start playback.
2. Rest a fingertip without clicking. Note whether taps track the kicks, feel consistently early/late, or are missing/extra. Check for discomfort or changes to regular clicking. Let the first run finish for a count comparison. On a separate run, press **Ctrl-C** several kicks into the playback and check that pulses stop and audio continues.
3. Save the terminal summary and beat trace as text. The fixture has 500 ms between kicks; gaps near 1,000 ms or 1,500 ms suggest missing beat reports inside the sequence. A continuous run of 500 ms gaps with a short count cannot identify which edge was missed. The summary reports first PCM delivery to the engine’s consumer, accepted requests, skips, and the p95 from detector-hop timestamp to software report and request. The latter is not measured playback-to-touch latency, and a request does not prove that a tap was felt. The shutdown callback measures when the engine returned. Check the separate `HAL cleanup` line for reported errors. A callback is not independent evidence that macOS released every underlying resource.

The live probe waits up to 15 seconds for audible PCM, then runs for at most 12 more seconds. It uses **Normal** beat sensitivity and the exact firmer waveform from the four-pulse test. It submits no more than 20 pulses, at least 250 ms after the previous request returned. Deadlines and cancellation are cooperative; there is no repeat or automatic restart. The normal Taptone app remains unchanged.

## Scope and verification

- Private `MultitouchSupport` symbol names, ABI assumptions, and waveform keys were cross-checked against [`os6/nospeaker` at `e02a121`](https://github.com/os6/nospeaker/blob/e02a121243f3dbddb288fa6520134b0c4a8727c6/nospeaker.swift#L71-L179). The wrapper and finite test sequence are separate from the main package.
- The unit tests use fake waits and requests; they never open a device. Run `swift test --package-path experiments/trackpad-probe --quiet`.
- The existence of a private symbol, or a successful driver return, does not prove correct hardware behavior. This experiment establishes neither long-session suitability nor cross-version support. It is not an App Store approach.
