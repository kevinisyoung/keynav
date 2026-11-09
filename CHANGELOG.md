# Changelog

## 0.2.8 — 2026-11-04

- Starting Scrolling while KeyNav's own Settings window is in front no longer freezes KeyNav.

## 0.2.7 — 2026-11-04

- Carrying a 0.2.5 license over no longer asks for your password: if macOS won't hand it over quietly, KeyNav skips it and you enter the key again.

## 0.2.6 — 2026-11-04

- KeyNav updates itself: it checks keynav.app once a day, and Check for Updates… is in the KeyNav menu, the menu bar menu and Settings › General.
- No more password prompt: the trial and license are kept in KeyNav's Application Support folder instead of the Keychain, and a license activated in 0.2.5 carries over.
- After a click the pointer stays hidden, even when another app comes forward, until you move the mouse.
- Clicking: a control reached twice, like Spotify's sidebar playlists, gets one label, and pointer clicks aim at a link's text, so Arc's small links (keynav.app's Buy) open.

## 0.2.5 — 2026-11-02

- KeyNav is now sold at keynav.app: every feature is free for 14 days, then a $39 license, bought once, keeps it working with every future update on up to three Macs. Settings › License buys, activates and frees a Mac.
- Clicking, Scrolling and Moving all work while a password field holds Secure Input, without bringing KeyNav to the front, and KeyNav names the app holding it.
- Clicking: Slack's sidebar rows open their conversation or app, Gmail's inbox rows open their email, Google's results open from their title, and Finder's desktop gets menu bar and Dock labels.
- Clicking labels far more: clickable cards, rows and icons on web pages, unnamed buttons and image links, map pins, custom toggles, and the panels of Raycast, Spotlight and 1Password. Chrome's links and buttons press directly instead of with the pointer, Finder and Notes label their toolbars and column headers, and an open popover is labelled alone.
- Scrolling shows at once and outlines only panes that scroll on their own: Slack's, Gmail's and Messages' columns, never a card or a page that scrolls as a whole, like Google or X. The outline holds still while scrolling and stays when the mouse leaves it.

## 0.2.4 — 2026-10-28

- Scrolling picks up where you last scrolled in each app, or else the pane you clicked in, and outlines it in blue. Every scroll area is numbered: Tab or its number moves there, and the outline follows the mouse.
- Scrolling parks off links and buttons so no tooltip pops up, refreshes hover when it stops (Notion tables scroll sideways), keeps the cursor hidden behind the dot, and stays on through screenshots.
- Clicking labels Slack's conversation, each message's hover actions, Messages' conversations, open menus, and each notification's Close, plus a notification stack's Clear and Show Less.
- Menu bar labels line up with their icons: icons hidden behind the notch no longer take a label.

## 0.2.3 — 2026-10-26

- Scrolling starts in the pane you last clicked in, even after switching apps and back. Tab and Shift Tab move between the window's scroll areas.
- Moving: Left Command no longer drags by default, so holding it for a shortcut can't grab the mouse. Holding Space still drags.

## 0.2.2 — 2026-10-26

- Clicking: the pointer hides after a label click, so it no longer covers the next label. Moving the mouse brings it back.
- Clicking: Spotify and other apps built on the Chromium Embedded Framework get labels.
- KeyNav stays out of the Dock and the app switcher unless Settings is open.

## 0.2.1 — 2026-10-26

- Moving: a Right Option tap no longer stops working after KeyNav misses a key release (after sleep, say).
- Clicking: the first use in Arc and other Chromium browsers labels the whole page, not just its top.

## 0.2.0 — 2026-10-24

- Moving: Shift Space right-clicks (was R).
- Settings: each mode's start and stop keys sit at the top of its page; Moving shows just its click keys.
- New icon: a hint label with the pointer about to click it.

## 0.1.0 — 2026-10-23

- Three modes, each with its own shortcut: Clicking (Command Shift Space), Scrolling (Command Shift J), Moving (Right Option tap). Escape stops any of them.
- Moving: I J K L move the pointer, Space clicks (hold to drag).
- Clicking labels the menu bar, status icons, Dock, and notifications too, skips controls hidden under other windows, and matches Homerow-style labels.
- Settings rebuilt as five short pages.

### Earlier development notes


- Two independent modes: Cursor (Right Option tap) and Click (Command Shift Space), each with an optional separate stop key (Escape).
- Cursor mode: time-based movement with a gentle smoothstep ramp, normalized diagonals, precision and boost holds, smooth scrolling, left/right/middle/back/forward clicks with real double-click counts, hold or toggle drag, help overlay, multi-display clamping.
- Label-click mode: bounded Accessibility discovery of the focused window or sheet, prefix-free labels, Unicode search, alternate actions, revalidation before every action, pointer fallback only on a revalidated control, honest “no targets” message.
- Settings: Overview with two entry cards and live previews, inline shortcut recorders with conflict resolution, presets with review, Mouseless import with review, export/import, reset with review, undo, search, appearance, per-app off, launch at login, optional menu-bar icon, diagnostics.
- Safety: one stop path that releases held input; sleep, lock, display change, permission loss, secure input, and tap interruption force Off; editing a Settings field pauses navigation.
- Tooling: unit tests, a fixture app, a live in-app self-test, Settings screenshot capture, build/install/package scripts.
