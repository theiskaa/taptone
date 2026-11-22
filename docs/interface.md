# Taptone interface

The menu turns taps on and off. The optional Activity window explains what they follow. Neither surface should make a small utility feel like a mixing console.

## Research → decisions

| Reference | What we used |
| --- | --- |
| Apple [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) and [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) | Keep a native template icon and native command menu. Put Start/Stop and Activity first; group tuning and troubleshooting below them. No custom popover to learn. |
| [Hand Mirror](https://handmirror.app/) | A useful reference for a narrow macOS utility: a compact menu bar entry point, with the larger surface only when you need it. |
| Apple [Charts](https://developer.apple.com/design/human-interface-guidelines/charts) and [Color](https://developer.apple.com/design/human-interface-guidelines/color) | One readable plot with sparse guides and familiar tick intervals. Shape, not color alone, distinguishes a detected accent from a tap request. Color adapts to appearance; the plot has an accessible summary and the readings are exposed as text. |
| Apple [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) and [Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | Native window controls, SF for UI, New York for one editorial wordmark, and tabular figures for changing values. |
| [`os6/nospeaker`](https://github.com/os6/nospeaker) | Its sparse signal plot lets the physical interaction remain the point. Borrow the restraint, not its terminal style, copy, or hardware implementation. |

## Design

- **Menu:** the Touch icon adds two marks above the fingertip while system listening is on. It does not flash on beats. A native section header identifies the current state; Start/Stop and Show Activity are the first commands. Sensitivity, diagnostics, and Quit stay available without occupying the Activity window.
- **Window:** warm paper and ink with a muted pine accent, one signal plot, three small readings, and a single prominent Start/Stop action. Demo and permissions support occupy the same secondary area rather than competing with the main control. The empty chart says what to do instead of showing fake input. When stopped, the chart freezes and labels the in-memory view “Last session.”
- **Semantics:** “Tap requests” is deliberately not “taps delivered.” Hollow circles are beats with no tap request; filled squares are beats with a request. Demo uses generated input and never produces taps. The controls remain standard keyboard-accessible macOS controls.
- **Scope:** this is presentation only. The normal app stays opt-in and public-API-only. No changes to the detector, capture lifecycle, pulse strength, telemetry, or private probe.
