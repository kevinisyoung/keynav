# Architecture

KeyNav is a Swift package with three library/app targets and a test fixture:

```
Sources/
  KeyNavCore/      Pure, deterministic logic. No AppKit. Fully unit-tested.
    Keys.swift              key codes, modifiers, Gesture, KeyEvent
    Configuration.swift     KeyNavConfig (schema 2), actions, presets, BindingChange diff
    ConfigStore.swift       validation, warnings, atomic JSON store, migrations, backup
    Bindings.swift          BindingTable: compiled lookup with explicit conflicts
    ModifierTap.swift       lone-modifier tap recognizer (left/right aware)
    CursorEngine.swift      time-based motion/scroll ramps, clicks, drag (hold/toggle)
    Hints.swift             prefix-free labels, Unicode search, ClickSession
    NavigationRouter.swift  the single owner of mode, generation, and routing
    MouselessImport.swift   reviewable translation of a Mouseless config.yaml
  KeyNavSystem/    macOS integration.
    EventTap.swift          active CGEvent tap + event classification
    CursorOutput.swift      posts tagged pointer/button/scroll events
    AccessibilityTargets    bounded AX discovery, revalidation, semantic actions
    NavigationService       glue: tap → router → effects; overlays; watchdogs
    Overlays.swift          nonactivating click-through panels (badge, labels, HUD, help)
    Permissions.swift       real capability probes (AX trust, active tap, secure input)
    DisplayGeometry.swift   multi-display clamping in global coordinates
  KeyNav/          The app: lifecycle, menus, Dock menu, Settings (SwiftUI), self-test.
  KeyNavFixture/   A controllable window for live tests. Not shipped.
Tests/KeyNavCoreTests/
```

## The one rule

Every input becomes a `RouterInput`; `NavigationRouter.handle` returns a `RouterDecision` (consume or pass, plus effects). `NavigationService.execute` performs effects. Nothing else changes which mode owns the keyboard or what KeyNav holds down. The router is a value type with no clock or OS access, so every policy below is unit-tested.

Resolution order for a key (spec §8.1): suspended (Settings field, recorder, excluded app) → release of a consumed key → modifier-tap entries → the active mode's root exit → global entries (including switching) → the active mode → pass through.

## Invariants and where they live

| Invariant | Mechanism |
|---|---|
| Two entries, one owner | `NavigationRouter.start` always calls `stop` first; one `mode` field. |
| Off means typing | Off consumes only entry gestures; tested by `testOffLettersProduceNoEffects` and live check L01. |
| Escape is predictable | Root exit is checked before mode keys; held drag modifiers are ignored when matching it. |
| No held button | `CursorEngine.reset` returns releases; every stop path (`stop`, `forceOff`, suspension, config change) runs it first; `CursorOutput.releaseAll` on quit. |
| No stale clicks | Generations on every start/stop; snapshot ids on every discovery; `AccessibilityTargets.revalidate` (role, position, size, enabled) before any action; a moved target triggers refresh, never a coordinate click. |
| Settings stay usable | When a KeyNav text field or recorder is first responder, routing is suspended (`SuspendsNavigation`). |
| Truthful indicator | Readiness is the result of a real active-tap probe in the running app, not a remembered flag. |
| Local data | Config holds bindings and preferences only. Diagnostics log content-free events. |

## Concurrency

All UI and routing run on the main actor. The event-tap callback runs on the main run loop and only routes (bounded work). Accessibility discovery runs in a detached task with a messaging timeout of 250 ms per element and node/depth/time budgets; results carry a generation and are discarded when stale. Activation is dispatched asynchronously so the tap callback returns quickly.

Timers run only while needed: a 120 Hz motion timer while a movement or scroll key is held, and a 1 s permission watchdog while a mode is on. Nothing polls while Off.

## Coordinates

All pointer and AX geometry is in global CoreGraphics points (origin at the top-left of the main display; other displays may have negative origins). Overlays convert to AppKit coordinates via the primary screen height.

## Settings UI

SwiftUI, hosted in an `NSWindow` with a `NavigationSplitView`. `AppModel.commit` is the only writer: it validates, saves atomically (keeping `config.previous.json`), applies to the service, and pushes an undo snapshot. Recorders (`ShortcutField`) capture with an AppKit view that suspends navigation while focused and never triggers the recorded action.
