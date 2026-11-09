# Compatibility

Verified configuration: **macOS 26.6.2 (25G83), Apple Silicon, Xcode 26.5, Swift 6.3.2**, KeyNav 0.1.0, signed with an Apple Development certificate, installed in /Applications. Nothing else has been verified; the macOS 14 deployment target is declared, not tested. Intel is not built or tested.

## Permissions observed on the verified Mac

The running app (probed as itself with `--diagnose-file`, not a shell) reported Accessibility granted, an active keyboard tap creatable, and Input Monitoring granted. Because both were granted, this does not establish whether Accessibility alone is sufficient. Before Accessibility was granted, the tap could not be created.

## Click discovery on real apps (read-only probe)

`KeyNav --probe-apps` on the focused window of each app, 2026-10-20. Nothing was clicked.

| App | Version | Window read | Targets | Time | Nodes | Notes |
|---|---|---|---|---|---|---|
| Finder | 26.4 | yes | 28 | 104 ms | 300 | File names appear as text fields, so labels sit on names rather than whole rows. Activation in Finder not yet checked. |
| Safari | 27.0 | yes | 8 | 18 ms | 24 | Probed on a local text file; toolbar buttons and address field found. Web page content not exercised. |
| TextEdit | 1.20 | yes | 2 | 24 ms | 12 | Document area and one button. |
| System Settings | 15.0 | yes | 16 | 326 ms | 277 | Slowest response, still within budget. |
| Arc (Chromium) | 1.168.0 | yes | 21 | 37 ms | 193 | Buttons, links, text fields. |
| Slack (Electron) | 4.52.178 | yes | 59 | 76 ms | 672 | |
| Notion (Electron) | 7.39.0 | yes | 59 | 88 ms | 698 | |
| Claude (Electron) | 3.1623.0 | yes | 32 | 61 ms | 377 | |
| Cursor (Electron) | 0.71.2 | yes | 27 | 39 ms | 170 | |
| Codex | 26.1013.31256 | yes | 77 | 81 ms | 735 | |
| Spotify (CEF) | 1.3.4.258 | yes | 114 | 125 ms | 1150 | |
| KeyNav Fixture canvas | — | yes | 0 | — | — | Correctly reports “No keyboard targets”. |

No probe hit the node, depth, or time limit.

Not covered: full-screen apps, multiple displays, scaled resolutions, menus and the menu bar, web page content in Safari and Chrome, password managers, remote desktop and virtual machine apps.
