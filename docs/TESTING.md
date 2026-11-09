# Testing

KeyNav evidence comes in three kinds. Every result says which kind it is.

| Kind | What runs | What it proves | Command |
|---|---|---|---|
| **Unit** (deterministic) | `KeyNavCore` with injected time and pointer | Routing, taps, motion maths, labels, search, config, migration, importer | `scripts/test.sh` |
| **Live synthetic** | The real signed app, its real event tap, real AX, the real fixture window; input is HID-level `CGEvent`s | The whole pipeline end to end on this Mac | `scripts/selftest.sh /Applications/KeyNav.app` |
| **Hardware / human** | A person on a physical keyboard | Physical modifier taps, feel, refresh rates, launcher results | Checklist below |

Synthetic events cannot prove how a physical keyboard reports left/right modifiers or how motion feels on a 120 Hz display.

## Live self-test

`scripts/selftest.sh` launches `build/KeyNavFixture.app` (buttons, a disabled button, a checkbox, two text fields, a target that moves or disappears on command, a pointer pad that records button events and drags, a scroll view, and a canvas window with no accessible content). It drives KeyNav through the event tap and checks the fixture's recorded state. All pointer, click, and scroll activity stays inside the fixture. It uses its own throwaway settings file. Results: `docs/evidence/selftest/selftest.md` and `.json`.

Don't type or move the mouse while it runs (about 90 seconds).

## Read-only compatibility probe

`open -n /Applications/KeyNav.app --args --probe-apps out.json com.apple.finder …` runs Click discovery on the focused window of each running app and records counts, timing, and role totals. It clicks nothing and records no names.

## Hardware checklist (human)

- [ ] Right Option tap on the built-in keyboard and an external keyboard starts Moving; Left Option does not.
- [ ] Option-letter characters (e.g. Option-E then E) still type accents; holding Option for half a second does not enter.
- [ ] Both Options held together, then released, does not enter.
- [ ] Movement feels gentle at start and stops immediately on release on a 60 Hz and a 120 Hz display.
- [ ] Moving across two displays (including one above the main display) is continuous; “Stay on the current display” confines it.
- [ ] Drag with Left Command held moves a Finder file; Escape mid-drag drops it.
- [ ] After using either mode and pressing Escape, typing in TextEdit is normal.
- [ ] Revoking Accessibility while Moving is on stops it within a second and Settings shows the reason.
- [ ] Lock the screen mid-drag; on return, KeyNav is off and nothing is held.
- [ ] KeyNav appears in Raycast and Spotlight results after quitting it completely.
