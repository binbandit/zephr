# Zephr — Design Document

**Product:** A keyboard-driven tiling window manager for macOS
**Name:** Zephr
**Status:** Draft v1 — intended to be handed to an engineering team or AI agent for implementation
**Date:** July 2026

---

## 0. How to read this document

This document is written to be sufficient for implementation without further product input. It contains: the market research and thesis (§1–3), the full UX specification (§4–5), the technical architecture including known macOS pitfalls and how to handle them (§6), phased milestones with exit criteria (§7), and success metrics, non-goals, risks, and open questions (§8–11).

Three invariants override everything else in this doc. If a feature conflicts with an invariant, the feature loses:

1. **Never lose a window.** No user action, crash, display change, or macOS update may ever leave a window unreachable. There is always a one-keystroke recovery path.
2. **Never require reduced system security.** No SIP disabling, ever. Signed and notarized from the first public build.
3. **Never stall.** One misbehaving app must never freeze window management for the rest of the system. Performance budgets in §6.3 are acceptance criteria, not aspirations.

**Implementation notes.** This document is the specification, not a changelog. The text below stays as written even where the shipped code has gone another way. Where that has happened, or where a section is not built yet, a `> **Status:**` note follows the paragraph it applies to. The notes are the honest record of the gap; the spec is still the thing being built toward, and an unmet acceptance criterion stays an acceptance criterion. For what exists today, see `CONTRIBUTING.md`.

---

## 1. The problem and the opportunity

Developers who come to macOS from Linux tiling window managers (i3, sway, Hyprland, xmonad) find the Mac's window model slow and mouse-dependent. A large ecosystem of third-party tools exists to fix this, and every one of them fails in a characteristic way. The market has split into three camps, and there is an unoccupied position between them.

**Camp 1 — Snappers** (Rectangle, Magnet, Loop, Moom, Raycast's window commands, and now macOS itself). Keyboard shortcuts that move one window to a zone: left half, right third, maximize. Reliable, simple, hugely popular — and being absorbed by the OS. Since macOS Sequoia, dragging to screen edges and keyboard tiling shortcuts are built in, and Apple keeps improving them. Snappers don't manage layouts: nothing happens automatically, there are no workspaces, nothing persists, and every new window is a manual chore. The most common story in developer forums is an i3 refugee who tried the real tiling managers, got burned, and "settled" for Rectangle. Settling is the word they use.

**Camp 2 — Power tilers** (yabai, AeroSpace, Amethyst, Rift). Real tiling: automatic layouts, workspaces, focus by direction. Powerful, and each one is hostile to newcomers in its own way. This is the camp we are entering, and its UX failures are the entire opportunity — they are catalogued in §2.

**Camp 3 — Commercial workspace apps** (Moom's saved layouts, TileOrg, BetterStage). Polished, GUI-first, project-oriented. They prove developers will pay for window management with good UX, but none of them is a real tiling window manager — no automatic layout, no i3-style tree, weak keyboard-first ergonomics.

The unoccupied position: **a real tiling window manager built with the product quality of a great Mac app.** i3's power, delivered with the onboarding of Things, the defaults of Ghostty, and the reliability of Rectangle. Nobody occupies this position. Every tool forces a choice between capability and civility.

---

## 2. Competitive research: where each incumbent fails

Research sources: current project documentation and GitHub issue trackers for AeroSpace, yabai, and Rift; the Hacker News discussion of Rift's launch (Oct 2025, 122 comments — an unusually candid sample of what this exact audience hates); Lobsters threads on macOS tiling; 2026 comparison roundups. Findings below are stated as engineering-relevant failure modes, since each one maps to a design decision later in the doc.

| Tool | Model | What it gets right | Where the UX fails |
|---|---|---|---|
| **yabai** | BSP tiling, CLI daemon, native Spaces | Most capable; scriptable everything | Full feature set requires partially disabling SIP — banned on most corporate machines and scary on personal ones. No built-in hotkeys (delegates to skhd, which is barely maintained). Config is shell scripts. Breaks with macOS updates. Users report multi-second input delays on some setups. |
| **AeroSpace** | i3-style tree, virtual workspaces, TOML config | Best i3 fidelity; no SIP required; built-in binding modes; huge mindshare (~21k stars) | Deliberately un-notarized (README tells users to bypass Gatekeeper). Explicit policy: will never have a GUI. Default keymap seizes every ⌥-key combination, destroying Emacs-style bindings and international character input — one HN commenter called it "the most hostile piece of software I have encountered in years." No tutorial. Virtual workspaces hide windows by piling them in a screen corner: users must manually rearrange their monitor layout so a corner is free, Mission Control fights the pile, and windows get stranded off-screen where users "hunt for them and hope." Reported stalls of several seconds under system load. Still labeled Public Beta in 2026; macOS 26 brought ghost windows, foreign windows leaking into the active workspace, and hotkey failures. |
| **Amethyst** | Automatic layouts (xmonad-style) | Zero-config automatic tiling; good for full-auto purists | All-or-nothing: every window gets tiled, including Slack, Spotify, and dialogs, which users experience as the app fighting them. Steep learning curve, dated UI, limited workspace story. |
| **Rift** | i3/AeroSpace-style, Rust, yabai-style internals | Extremely fast — proves low latency is achievable; per-display workspaces | Built on reverse-engineered private APIs (fragility across macOS updates is a matter of when, not if). Install was compile-from-source at launch. Same corner-stash workspace leaks. Native-tab handling causes windows to jump when tabs close. No GUI, no onboarding. |
| **Rectangle / Magnet / Loop / native macOS** | Snapping | Trustworthy, instant, zero learning curve | Not tiling: no automatic layout, no workspaces, no persistence, no focus-by-direction. And Apple is steadily absorbing this feature set. |
| **Moom / TileOrg / BetterStage** | Saved layouts / project workspaces | Saved layouts and two-keystroke palettes are beloved; proof of willingness to pay | No automatic tiling; not keyboard-first at the i3 level; no tree model. |

### The seven recurring failure modes

Synthesizing across all sources, the same complaints appear over and over, regardless of tool:

1. **Trust and setup friction.** SIP disabling, unsigned binaries, compile-from-source, separate hotkey daemons. Before the user has tiled a single window, the tool has asked them to lower their guard.
2. **Zero discoverability.** Forty keybindings documented only in a config file. Modal systems with no on-screen indicator of which mode you're in. No tutorial anywhere in the category. The learning curve isn't the concept — it's that nothing teaches you.
3. **Keybinding conflicts.** The single most common day-one failure. Global chords collide with IDE shortcuts, Emacs bindings, and international keyboard input (⌥ produces characters like é and ˙ on many layouts — seizing ⌥ breaks typing). Power users all converge on the same self-built fix: a leader key with modes, via Karabiner and custom config. The fix is known; no tool ships it as the default experience.
4. **Workspace leakage.** Virtual workspaces (the only SIP-free approach, since Apple provides no public API for controlling Spaces) are implemented by shoving windows into a screen corner. The seams show constantly: visible window slivers, Mission Control clutter, stranded windows, homework for the user ("arrange your monitors so a corner is free").
5. **Latency and stalls.** The Accessibility API is slow and synchronous per-app; naive architectures let one busy app freeze all window management for seconds. Rift proved this is an architecture problem, not a platform ceiling.
6. **Fragility across macOS updates.** Every September, everything breaks. Tools built on private APIs break hardest; even public-API tools ship fixes for weeks after each release.
7. **All-or-nothing tiling.** Real workflows are mixed: tile the editor, terminal, and browser; float the music player, the picker dialog, and the video call controls. Tools that tile everything feel aggressive; tools that tile nothing feel useless. Native macOS tabs (Finder, Ghostty, Safari) break every tiler's model.

Every one of these seven has a direct answer in this design. That mapping — not a longer feature list — is how we beat them.

---

## 3. Product thesis

**One sentence:** the tiling window manager that feels like it shipped with the Mac.

**Positioning line (draft):** *All of i3. None of the hostility.*

**Target user, in priority order:**

1. The i3/sway/Hyprland refugee on a work MacBook — can't disable SIP, won't run unsigned binaries, misses their Linux setup daily. Currently "settling" for Rectangle or white-knuckling AeroSpace.
2. The macOS-native developer who has heard of tiling, is keyboard-oriented (uses Raycast, vim bindings, a terminal multiplexer), but has bounced off the config-file wall every time they tried.
3. The current AeroSpace/yabai user who is tired of stalls, lost windows, and September breakage. This group is small but is the entire early word-of-mouth engine — they write the blog posts and HN comments.

**How we win.** Not feature count. Six bets, each aimed at one or more of the seven failure modes:

- **Bet 1 — Sixty seconds to tiled.** Signed, notarized, drag-to-Applications. One guided permission. Working defaults with zero config. An interactive 90-second tutorial that uses the user's real windows. (Failure modes 1, 2.)
- **Bet 2 — A discoverable command layer.** A leader key opens an on-screen command strip that shows what every key does — the "which-key" pattern that power users currently hand-build. Modes are always visibly indicated. Experts graduate to direct chords; the layer teaches them as you go. Default chords use ⌃⌥, never bare ⌥, so international typing and Emacs bindings survive. A first-run conflict scanner picks a leader key that doesn't collide with the user's existing shortcuts. (Failure modes 2, 3.)
- **Bet 3 — Tiling that never fights you.** Tile by default, float what should float — automatically. A curated, shipped database of per-app rules plus structural heuristics (dialogs, non-resizable windows, utility panels float on their own). Per-workspace tiling/floating modes. Native-tab awareness. (Failure mode 7.)
- **Bet 4 — Workspaces without seams.** The virtual-workspace approach, engineered properly: no monitor-arrangement homework, a continuous reconciliation loop, a hybrid stash that keeps Mission Control clean, and a hard "never lose a window" invariant with a one-key rescue command. (Failure mode 4.)
- **Bet 5 — Layouts that survive real life.** The killer feature nobody in Camp 2 has: display profiles. Unplug your monitor, everything migrates gracefully; plug it back in, everything returns to exactly where it was. Plus session restore across restarts, and (post-1.0) named project layouts that launch and arrange apps. This is the feature people tell coworkers about. (No incumbent failure mode — this is offense, not defense.)
- **Bet 6 — Boring reliability.** Public APIs only. Per-app isolation so a slow app can't stall the manager. Tested against macOS betas every summer. Crash-safe window-position snapshots. Notarized, auto-updating, uninstall restores every window. (Failure modes 1, 5, 6.)

**What "beating them" looks like in a review:** "I installed it at lunch, didn't read any docs, and by the end of the day I'd stopped thinking about windows. When I got home and docked, my whole layout came back. I never opened the config file."

---

## 4. UX specification

### 4.1 First run

The install is a notarized .app in a DMG (plus `brew install --cask zephr` from day one). First launch, in order:

1. **Welcome** — one screen, one sentence of promise, one button. No account, no email, no telemetry prompt (see §8 for the opt-in approach).
2. **Accessibility permission** — a single screen that shows a 5-second looping screen recording of exactly what to click in System Settings, explains in one sentence why the permission is needed (window control requires the Accessibility API; that's true of every app in this category), and detects the grant automatically the moment it happens. No dead ends: if the user returns without granting, the screen offers a "remind me later" path that leaves the app dormant in the menu bar rather than broken.
3. **Leader key selection** — the app scans for conflicts (registered global hotkeys where detectable, Spotlight/Raycast/Alfred bindings, input-source switching shortcuts, common IDE defaults) and proposes a leader key, default **⌥ Space**, with two pre-checked alternates (⌃⌥ Space, ⌘⌥ Space) if a conflict is found. One click to accept; a "choose my own" recorder for the opinionated.
4. **Interactive tutorial (~90 seconds, skippable, replayable from the menu bar)** — the tutorial does not use a video or screenshots; it drives the user's actual windows. It opens two harmless windows of its own if fewer than two exist. Steps: press leader → see the command strip → focus left/right with `h`/`l` → move a window with `⇧L` → make a new split → switch to workspace 2 with `2` and bring a window with `⇧2` → toggle a float with `t` → open the palette with `p` and fuzzy-jump to a window → done. Each step highlights the relevant key in the strip and waits for the real action. On completion: "You know 80% of it. Press leader, then `?`, any time to see everything."
5. **Optional: import** — if an `.aerospace.toml`, Amethyst plist, or Rectangle config is detected, offer to import bindings and rules, with a plain-language report of what mapped and what didn't (§4.7).

Acceptance criterion for this whole flow: a user who has never used a tiling window manager reaches their first successful keyboard-driven tile within 2 minutes of opening the DMG, and can move/focus/switch workspaces unaided within 5. This is tested with real people before launch (§7, Phase 3).

> **Status:** the flow is built - welcome, permission screen with grant detection and a "remind me later" path, leader picker, interactive tutorial with self-checking steps and its own practice windows, and the AeroSpace/Amethyst importer. Three gaps: step 2's 5-second screen recording does not exist (needs a real recording); step 3's "conflict scan" only detects Raycast and preselects ⌃⌥ Space, rather than scanning registered hotkeys, Spotlight/Alfred, input-source switching, and IDE defaults; and the DMG waits on the notarization pipeline (§6.7). The acceptance criterion has not been run with recruited testers.

### 4.2 The interaction model: leader layer + direct chords

Two ways to do everything; both always available; the first teaches the second.

**The leader layer.** Pressing the leader key (default ⌥ Space) opens the command layer:

- A **command strip** appears bottom-center within 50 ms: a compact, native-material (translucent) horizontal HUD showing the available keys grouped by verb — Focus, Move, Split, Layout, Workspaces, Windows, Help. Each key is rendered as a keycap with a two-word label. The strip is one line tall by default; pressing `?` expands it into the full cheat sheet overlay.
- While the layer is open, keystrokes are consumed by Zephr (never leak to the app below) and act **immediately** — this is a command layer, not a menu you navigate.
- The layer is **sticky by default**: it stays open so `h h h ⇧L 3` flows as one thought. It closes on `Esc`, on pressing the leader again, or after a configurable idle timeout (default: none). A one-shot mode (layer closes after a single command) is available in settings for people who prefer it.
- Mode state is **always visible**: the strip itself, plus a tint on the menu-bar item. No invisible modes, ever — this is a direct fix for the "which mode am I in?" complaint with skhd/AeroSpace modes.
- **Progressive disclosure:** after the user has executed the same layer command ~10 times, the strip shows a one-time inline hint: "Tip: ⌃⌥L does this without the leader." The layer is the tutorial for the chords.

**Direct chords.** Every high-frequency command also has a global chord for zero-latency expert use. Defaults are built on **⌃⌥** (and ⌃⌥⇧ for the "move" variants) — chosen specifically because ⌃⌥ combinations produce no characters on any standard layout, so international typing (⌥e → é) and Emacs/readline bindings survive untouched. This is a deliberate, documented contrast with AeroSpace's bare-⌥ defaults and should be called out in marketing to that audience.

**Default keymap** (every binding rebindable; presets ship for i3, AeroSpace, and Vim-purist styles):

| Action | In leader layer | Direct chord |
|---|---|---|
| Focus left / down / up / right | `h` `j` `k` `l` (or arrows) | ⌃⌥ H/J/K/L |
| Move window left/down/up/right | `⇧H` `⇧J` `⇧K` `⇧L` | ⌃⌥⇧ H/J/K/L |
| Go to workspace 1–9 | `1`–`9` | ⌃⌥ 1–9 |
| Send window to workspace 1–9 | `⇧1`–`⇧9` | ⌃⌥⇧ 1–9 |
| Toggle float on focused window | `t` | ⌃⌥ T |
| Monocle (maximize within tile, toggle) | `m` | ⌃⌥ M |
| Split horizontal / vertical (next window) | `s` / `v` | — |
| Cycle container layout (tiles ↔ accordion) | `space` | — |
| Resize mode (then h/j/k/l in 5% steps, ⇧ for 1%) | `r` | ⌃⌥ - / ⌃⌥ = (shrink/grow) |
| Balance sizes in container | `=` | — |
| Window palette | `p` | ⌃⌥ P |
| Rescue all windows to current workspace | `w` | — |
| Focus next display | `tab` | ⌃⌥ ` |
| Full cheat sheet | `?` | — |
| Close layer | `esc` or leader | — |

> **Status:** shipped as written, plus commands this table predates. In the layer: `q` close window (also ⌃⌥Q), `g` group with the next window, `⇧G` flatten the workspace, `o` flip a group between row and column, `⇧tab` send the focused window to the next display (also ``⌃⌥⇧` ``), `d` send the whole workspace to the next display, `⇧D` pause tiling on this display alone. Two divergences: **balance** (`=`) evens out every tiled container in the workspace, not just the focused one - balancing one container cannot be composed into balancing the workspace, since focusing each window in turn undoes the previous press; and **resize** takes an explicit sign, so right/down always grow and left/up always shrink, and a tile at a hard edge does nothing rather than reversing. "Every binding rebindable" is now true in one direction only: a `[[bind]]` block can point any chord or layer key at any command in the shared `zephrctl` vocabulary, and is consulted before the built-in tables, but a built-in key cannot be *unbound* and passed through to the app below.

**The palette.** `leader → p` (or ⌃⌥P) opens a fuzzy-search palette, visually kin to Spotlight/Raycast: type to filter across **windows** (app icon, window title, workspace badge — Enter focuses it, switching workspace if needed), **workspaces**, **commands** (every command in the app, searchable by name — this is also the discoverability escape hatch: anything you can't remember a key for, you can type), and **saved layouts/profiles**. This single surface answers three recurring forum requests at once: deterministic app switching by name, keyboard window-switching across workspaces, and "what was that command called?"

> **Status:** windows (including native-fullscreen and off-Space ones, marked and summoned by activating their app), workspaces, "bring workspace *n* here" on multi-display setups, and a hand-maintained list of the everyday commands. "Every command in the app" is not yet true: the list has not grown with the commands added since - group, flatten, row ↔ column, the display moves, per-display pause, shrink/grow, send-to-workspace. Saved layouts/profiles are not in the palette either; profiles live in Settings.

### 4.3 The tiling engine

**Model:** an i3-family tree. Each workspace owns a tree; leaves are windows; interior nodes are containers with an orientation (horizontal/vertical) and a layout (`tiles` or `accordion`). Normalizations on by default (single-child containers flatten; nested containers alternate orientation) so the on-screen result always visually matches the tree — the AeroSpace normalization insight, kept.

**Placement without ceremony:** a new window splits the focused window along its longer edge. This gives beginners good layouts with zero commands (BSP-feel) while `s`/`v` pre-selects the split for the next window when the user wants control. The result must be **predictable**: same action, same result, every time. No layout algorithm that reshuffles existing windows when a new one arrives.

**Floating, done for you:** the fix for "tiling fights me" is that the right windows float automatically:

- **Structural heuristics** (always on): AX subroles for dialogs, sheets, and system dialogs; non-resizable windows; windows smaller than 500×350 at creation; utility/panel window classes; modal windows. These float, positioned centered or where the app put them.
- **Shipped per-app rules:** a human-readable rules file bundled with the app covering ~50 common offenders at launch (System Settings, Finder progress/copy dialogs, Zoom's floating controls, 1Password's quick-access panel, picture-in-picture players, color/font pickers, launcher palettes like Raycast/Alfred which must be ignored entirely, etc.). The file lives in the repo; community PRs extend it; the app ships updates to it via the normal update channel.
- **User rules with zero syntax:** in Settings → Rules, a "pick a window" crosshair lets the user click any window and choose: always float / always tile / always workspace N / ignore. The rule is written for them (app bundle id + optional title pattern) and, like all settings, lands in the config file (§4.6).
- **Per-workspace mode:** any workspace can be flipped to floating-by-default (for the "junk drawer" workspace pattern) while others tile.

> **Status:** the structural heuristics, per-workspace mode, and user rules are in. Two additions this section predates. First, a **window-level check**: screen-share control bars, screenshot overlays, reminder popups, and picture-in-picture panels all report themselves through AX as standard windows with a close button, so adoption also reads `kCGWindowLayer` from the public window list and refuses anything above the normal layer. The AX element and the CG entry are joined on pid and bounds - the identifier that would join them exactly is a private API (§6.1) - so an ambiguous match deliberately answers "no information" and the window is kept. Second, **minimum sizes are learned, not punished**: an app that comes back bigger than the requested frame on one axis and no smaller on the other is stating a minimum, and the solver records it (per axis, believed only on a second identical read-back, since a read-back taken straight after a write can be stale) instead of the veto path floating an ordinary editor. The shipped rules database is around twenty entries, well short of the ~50 the section calls for, and Settings offers "Add Rule for Focused Window…" rather than the pick-a-window crosshair.

**Native tabs:** macOS merges tabbed windows (Finder, Terminal, Safari, Ghostty) in ways the AX API reports poorly, and every incumbent mishandles the moment a tab closes — neighboring windows jump. Design requirement: tab merge/close events trigger **reconciliation** (§6.4) rather than naive re-layout — the tree updates to the new reality without moving any window the user didn't touch. Where the AX tab-group attribute is readable, a tab group is treated as a single leaf. Full first-class tab support is post-1.0 (§7); *not corrupting the layout* when tabs change is a 1.0 requirement.

**Gaps and looks:** inner/outer gaps configurable, default small (8px) and on — it reads as intentional design and aids focus-tracking. An optional focused-window border (2px, accent color, drawn via a borderless overlay window) is on by default at low opacity; it's the single most useful visual cue for newcomers learning where focus is. All movement animates with system-standard timing and fully respects Reduce Motion. No further ricing (see Non-goals).

> **Status:** gaps and the border ship as described; the border's color, width, and corner radius are configurable beyond the spec (the radius defaults to tracking the system window radius, which grew in macOS 26), and it stops drawing over a display a native-fullscreen window has taken. **Movement does not animate, and cannot.** Frames are written through `AXUIElementSetAttributeValue`, which sets a window's position and size outright; there is no public way to interpolate another app's window. Every move is instant. That is the Reduce Motion behaviour the spec asks for and the only behaviour available, so the animation clause should be read as unbuildable rather than pending.

**Manual escape hatches always work:** dragging a window by its title bar auto-floats it for the drag and offers drop targets to re-tile (drop zones appear over container edges); resizing a tiled window with the mouse on a gap adjusts the split (8px invisible hit area). Keyboard-first must never mean mouse-hostile — this is a Mac.

### 4.4 Workspaces and multi-monitor

**Model:** virtual workspaces `1–9` plus optional named workspaces, independent of macOS Spaces. Apple provides no public API to create, switch, or move windows between Spaces — this is precisely why yabai needs SIP off — so like AeroSpace and Rift we emulate our own. Unlike them, the emulation must be seamless. The app manages the current native Space and leaves windows on other Spaces and native-fullscreen windows untouched (they appear in the palette, marked, and can be summoned).

> **Status:** built, as far as the public API allows. `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` lists only the windows on the active Space, so a window the model expects to be visible and cannot find there has moved away; it is withdrawn from the layout and returns when it comes back. Matching is on owning process and bounds - never on `kCGWindowName`, which would require Screen Recording and break invariant 2 for a cosmetic gain - and it is deliberately conservative: a *count* shortfall per app is the primary signal, frames only break ties, and if every candidate vanishes at once that is read as a Space switch rather than a migration and nothing is withdrawn. Zephr still cannot create, switch, or move windows between Spaces, and does not try to. The matching logic is unit-tested; the probe has not been exercised against a real multi-Space desktop.

**Per-display workspaces (the dwm/i3 model):** each display shows its own active workspace; workspaces have a home display and an affinity list. `⌃⌥ Tab` (or leader → tab) moves focus between displays; moving a window past the last split on a display edge carries it to the neighboring display. Rationale: this was an explicit complaint about the single-global-workspace model and is what multi-monitor developers expect from Linux.

**The stash — hiding without seams.** Inactive-workspace windows are moved off-screen. Three engineering requirements fix the incumbents' leaks:

1. **No homework:** the stash anchor is computed per display arrangement automatically — the engine finds usable off-screen space for every display in any arrangement. The user is never asked to rearrange monitors in System Settings.

   > **Status:** built, and the anchor is a bottom **corner**, not an edge. macOS clamps how far below a display a window may sit - it keeps the title bar reachable - so "one point past the bottom edge" lands tens of points short and leaves a full-width strip of window showing. Horizontal displacement has no such clamp, so the window goes off to the side and down together; even when the vertical part is clamped back, only a sliver-wide column can show. Four candidates (both bottom corners, then due east and west for displays flanked on both sides) are ranked by how little they spill onto a neighbouring display, so a one-point leak still beats a fallback that leaves the window mostly visible. The seams are reduced, not eliminated - see §10.

2. **Clean Mission Control:** when *all* of an app's windows are stashed, the app is additionally hidden via the public `NSRunningApplication.hide()` — hidden apps vanish from Mission Control and the corner pile. When any window of the app returns to an active workspace, the app is unhidden first, then placed. (Per-window hide doesn't exist in public API; per-app hide is the best available primitive and covers the common single-window-per-app case, which is most of the pile.)
3. **Never lose a window:** a reconciliation audit (§6.4) continuously verifies every managed window is either visible in its active workspace or fully in the stash. `leader → w` rescues *everything* to the current workspace and re-tiles. On quit, crash (via exception/signal handler), or uninstall, all windows are restored to visible positions from the last snapshot. This invariant is tested, not hoped for.

**Workspace indicator:** the menu-bar item shows the current workspace symbol per display; clicking it shows a mini switcher. An events API (§4.8) feeds SketchyBar and friends for people who want more.

### 4.5 Display profiles and session persistence — the signature feature

**Display profiles.** A profile is fingerprinted by the set of connected displays (identifier + resolution + arrangement). Zephr continuously snapshots, per fingerprint: the workspace→display mapping, each workspace's tree with split ratios, floating window frames, and per-window workspace assignments.

- On display change (dock, undock, projector, lid close/open), reconfiguration is debounced (~500 ms — macOS fires storms of these events), then: if the new fingerprint is known, restore it exactly; if unknown, migrate workspaces from vanished displays to the remaining ones in stable order and start recording the new profile.
- The acceptance test, verbatim: *undock a laptop with 14 windows across 6 workspaces on 2 external displays; work on the laptop screen; redock. Every window returns to its exact workspace, display, position, and split ratio. Fifty consecutive round-trips, zero deviations.*

**Session restore:** window→workspace assignments and trees persist across app restarts and reboots (matching returning windows by app + title heuristics as they reappear, since macOS assigns new window identities). Best-effort, but the common case — restart Mac, apps reopen, layout reassembles — must work.

**Named layouts (post-1.0, v1.1):** user-defined layouts ("deep work", "code review") that can launch missing apps by bundle id and place their windows into a defined tree, triggered from the palette or a chord. This is Moom's most-loved feature raised to tiling. Specified now so the data model (§6.5) accommodates it; built after 1.0.

### 4.6 Configuration: GUI and config file, one source of truth

The category is split between GUI-only tools (excluding power users) and file-only tools (excluding everyone else, by explicit policy in AeroSpace's case). Zephr refuses the split:

- **A native SwiftUI Settings window** covering everything: General (leader key, login item, updates), Keys (a recorder with live conflict warnings; preset schemes: Default, i3, AeroSpace, Vim), Layout (gaps, border, accordion padding, animations), Rules (the per-app table with the pick-a-window crosshair), Workspaces (names, display affinity, per-workspace mode), Profiles (view/rename/delete display profiles), Advanced.
- **A plain-text config file** at `~/.config/zephr/config.toml` — TOML, dotfiles-friendly, hot-reloaded on save with inline validation errors (line numbers, "did you mean" suggestions), never silently ignored.
- **Round-trip guarantee:** the GUI reads and writes the same file, preserving user comments, key order, and formatting (implementation: a lossless TOML document model, i.e. toml-edit-style, not parse-to-struct-and-dump). A power user's hand-edited, version-controlled config survives GUI use untouched except for the keys actually changed. This guarantee is a headline feature for exactly the audience that distrusts GUIs — state it in the docs and keep it under test.
- **Doctor:** `zephr doctor` validates config, permissions, conflicting apps (detects yabai/AeroSpace/Amethyst running simultaneously and says so plainly), and Secure Input state.

> **Status:** the Settings window covers General, Layout, Rules, Workspaces, and Profiles; there is no separate Keys tab, and the leader and preset pickers live under General. Doctor is built (`zephrctl doctor`, with JSON output) and also reports Stage Manager. **The round-trip guarantee is met by construction, not by a lossless document model.** Writeback is line-targeted surgery (`ConfigEdit` in Core, pure and round-trip tested): it rewrites only the lines whose keys changed and leaves every other byte of the file alone, comments and ordering included. That satisfies the guarantee for the keys Settings can write, but it is not the toml-edit-style model the section specifies, and it is why arbitrary structural edits are still a P4 item. Config parsing is likewise a hand-rolled parser for the documented subset, not a full TOML implementation.

### 4.7 Migration as a feature

Switchers are the launch audience, so switching is a first-class flow, not a wiki page:

- **AeroSpace importer:** reads `.aerospace.toml`, maps modes→layer bindings, keybindings, gaps, and per-app rules; produces a plain-language report ("34 of 39 bindings mapped; these 5 have no equivalent, here's why"). Target: a working migration in under 10 minutes.
- **Amethyst / Rectangle:** import shortcut schemes and float lists where they exist.
- **Presets:** the i3 preset makes muscle memory portable on day one.

### 4.8 CLI and scripting

`zephrctl` — a small CLI speaking to the app over a Unix domain socket. Not required for anything (contrast: yabai without skhd can't even bind a key) but present for the audience that scripts:

- `zephrctl focus left`, `move-to-workspace 3`, etc. — every command in the app, same names as the palette shows.
- `zephrctl list-windows --json`, `list-workspaces --json` — stable JSON schemas.
- `zephrctl subscribe` — an event stream (focus_changed, workspace_changed, display_changed, window_managed/unmanaged) that makes SketchyBar/Übersicht integrations one-liners. Shell out via config callbacks is also supported (`on-workspace-changed = "..."`).

---

## 5. Visual and interface design principles

Native materials everywhere (the command strip and palette use system translucency and vibrancy); SF Symbols; system accent color for the focus border; light/dark automatic. Animation uses system curves and durations and honors Reduce Motion completely (instant repositioning, no fades). The menu-bar item is quiet: workspace glyph only, no badge noise. There is no dock icon by default (menu-bar app), a setting flips it on. Nothing in the UI should look like it came from Linux; everything should look like Apple could have shipped it — that gap between "clearly native" and "clearly bolted on" is half the word-of-mouth thesis.

The app must remain fully usable without ever opening Settings, and fully configurable without ever opening Settings. Both at once. That sentence is the design review test for every feature.

---

## 6. Technical architecture

### 6.1 Stack and targets

- **Language:** Swift 6, strict concurrency. AppKit for windowing/overlays; SwiftUI for Settings, onboarding, HUD content.
- **Targets:** macOS 14 Sonoma minimum; 15 Sequoia and 26 Tahoe are primary test targets (Tahoe changed AX behaviors and broke incumbents — being *good on Tahoe* is a launch wedge).
- **APIs — public only:** Accessibility (`AXUIElement`, `AXObserver`) for window enumeration and control; `CGEventTap` for the leader/chords (with the Carbon `RegisterEventHotKey` fallback for chords when Secure Input blocks taps); `NSWorkspace` for app lifecycle; `CoreGraphics` display reconfiguration callbacks + `NSScreen` for displays; `CGWindowListCopyWindowInfo` for z-order hints; `NSRunningApplication.hide()` for the clean stash.
- **Private APIs: none.** This is stricter than AeroSpace (which uses one, `_AXUIElementGetWindow`, to get a window's CGWindowID) and categorically unlike Rift/yabai. Window identity is tracked by `AXUIElement` reference equality per pid; CGWindow correlation, where needed for z-order, uses pid + frame + title matching. If implementation proves an unavoidable need for the one AeroSpace-style call, it goes behind a build flag with graceful degradation and gets listed in the docs — but the default answer to "can we use a private API for this?" is no, redesign. (Rationale: §2, failure mode 6; also the entire trust story.)

> **Status:** holding - no private API is called and no build flag exists for one, so open question 4 has not had to be answered. `CGWindowListCopyWindowInfo` has grown two uses beyond the z-order hints listed above, both on the same public call and both correlating by pid and bounds: window **level**, to refuse overlays that describe themselves through AX as standard windows (§4.3), and active-Space **membership** (§4.4). `kCGWindowName` is deliberately never read, since it would pull in the Screen Recording permission. A single file (`SpaceProbe`) owns the call so that surface stays reviewable, and `just lint` (a CI job) greps the sources for the known private entry points - SkyLight, `CGSDefaultConnection`, `_AXUIElementGetWindow`, `dlsym`, `@_silgen_name` - and fails on a hit.

### 6.2 Process shape and modules

Single user-space app (menu-bar `LSUIElement`), no daemon, no helper with elevated rights. Modules:

- **Core** — pure Swift package: the workspace/tree/window model, the command interpreter, layout solver, and profile store logic. Zero AppKit imports, 100% unit-testable, property-based tests on tree operations (any sequence of split/move/close commands preserves invariants: no orphan nodes, ratios sum to 1, normalizations hold).
- **WindowService** — the only module touching AX. One actor per target application (see §6.3).
- **HotkeyService** — event tap ownership, leader-layer state machine, Secure Input detection (poll `IsSecureEventInputEnabled`; when active, show a menu-bar indicator explaining why keys are limited — never fail silently).
- **WorkspaceEngine** — stash strategy, per-display active-workspace state, reconciliation.
- **DisplayService** — reconfiguration debouncing, fingerprinting, profile apply/migrate.
- **ConfigService** — lossless TOML document model, file watcher, validation, GUI binding layer.
- **IPC** — Unix socket server for `zephrctl`, JSON codecs, event fan-out.
- **UI** — command strip, palette, borders/overlays, settings, onboarding.
- **Updater** — Sparkle 2, signed appcasts.

Layout math: proportional splits with per-window minimum-size constraints (many Mac apps enforce minimums; the solver clamps and redistributes rather than producing overlaps — when a container can't satisfy all minimums, it degrades that container to accordion and surfaces a subtle hint).

> **Status:** the module boundaries hold, with two exceptions. **Updater** does not exist: Sparkle is not integrated and there is no appcast, because both need an Apple Developer ID and hosted infrastructure (§6.7). **ConfigService** is file IO, hot reload, and error surfacing only; the document editing lives in Core as `ConfigEdit` so it can be unit-tested without a filesystem, and it is line-targeted rather than a lossless TOML model (§4.6). The layout math is built as specified, including clamp-and-redistribute and the accordion degradation, and minimums are learned from write read-backs rather than guessed (§4.3). The "subtle hint" when a container degrades is not implemented - the degradation is silent.

### 6.3 The anti-stall design (this section is why we're fast)

The AX API is synchronous and per-process; a busy or hung app answers AX requests in hundreds of milliseconds or never. Incumbent stalls come from serializing all AX work on one queue. Requirements:

- **One actor per target app.** All AX calls for a given pid run on that app's actor. A slow Xcode can never delay focusing Ghostty.
- **Deadlines on every AX call** (default 250 ms via `AXUIElementSetMessagingTimeout` plus task-level timeout). A timed-out app is marked degraded: its windows stay managed with cached geometry, a retry ladder (100 ms / 500 ms / 2 s) restores it, and the UI never blocks on it.
- **Write coalescing:** layout application batches set-frame calls per app, ordered to minimize visible reflow (shrink before grow), skipping no-op writes.
- **Perceived latency budgets (acceptance criteria, measured in CI with a synthetic 20-window harness):** focus change p95 < 50 ms; window move within workspace p95 < 100 ms; workspace switch p95 < 120 ms; leader strip visible < 50 ms after keydown; idle CPU < 0.5%; RSS < 80 MB with 50 managed windows. Instrument with os_signpost; a perf regression fails the build.

> **Status: these budgets are not enforced.** They remain acceptance criteria and none of them is being softened here; what follows is what is actually true today. The os_signpost intervals exist and are the only part of that bullet that ships: they are emitted for Instruments to pick up, and are asserted nowhere. There is no synthetic 20-window harness. CI (`.github/workflows/ci.yml`) runs exactly three jobs - `just lint`, `just ci-core`, `just ci-app` - so no timing regression can fail a build. **None of the four latency p95s has been measured.** Idle CPU has: 0.0% on a four-minute-old process on an idle desktop, comfortably inside the budget, though not under load. The memory budget also names the wrong metric for macOS. RSS on a GUI process counts the shared framework text pages every app maps (AppKit, SwiftUI, CoreGraphics), which is roughly 70 MB before Zephr allocates anything - a spot measurement with 6 managed windows read 95.8 MB RSS against a `phys_footprint` of 26.5 MB, peak 28.8 MB. `phys_footprint` is what Activity Monitor shows as "Memory" and what the OS uses for pressure decisions, so the budget should be restated in that metric when it is next revised. The 50-window case has not been measured at all.

### 6.4 Event handling and reconciliation

Event-driven first: `AXObserver` notifications (created, destroyed, moved, resized, focused, title changed, application activated/hidden) plus `NSWorkspace` app lifecycle. But AX notifications are lossy in practice — Tahoe's ghost-window and foreign-window bugs in incumbents are missed/false events. Therefore, a **reconciliation loop**: on every event burst and on a 2-second idle audit, re-enumerate reality (windows per app, frames, liveness) and diff against the model. Liveness is checked cheaply (an attribute read returning `kAXErrorInvalidUIElement` purges the ghost). All corrective actions flow through reconciliation — including native-tab merges/closes (§4.3) — so the system converges instead of compounding errors. The model is the single source of truth for intent; reality is polled for drift; the diff is applied minimally.

> **Status:** built, with the audit cadence traded against battery: the pass runs every 3 s while the desktop is active, and once ten seconds have passed with no event or command it drops to a deep sweep every ~30 s (with a one-second timer tolerance so the OS can coalesce wakeups). The 2-second figure in the text would keep the machine awake for nothing on an idle desktop. The Space check (§4.4) and the scan for newly launched apps ride the ~30 s tick, plus a 400 ms debounce after a Space-change notification.

Known macOS pitfalls the implementation must handle (each becomes a test):

- **Electron/Chromium sizing:** set `AXEnhancedUserInterface = false` on target apps before frame writes and restore after; otherwise frames misapply (well-documented community workaround).
- **Window exists before AX is ready:** creation events can fire before the element accepts commands; retry ladder 10/50/250 ms.
- **Sheets/drawers/child windows** follow their parent and are never independently tiled.
- **Apps that clamp or veto frames** (Settings-style fixed windows): detect the veto (read-back after write), auto-float, learn the rule.
- **Mission Control / Exposé transitions** fire bursts of bogus geometry: debounce, and never write frames while a transition is suspected (all-windows-moved-simultaneously heuristic); reconcile after.
- **Stage Manager:** incompatible by nature; detect it enabled and tell the user plainly with a one-click "turn off Stage Manager" deep-link, rather than misbehaving mysteriously.
- **Native fullscreen** windows are unmanaged, listed in the palette, marked.
- **Secure Input** (password fields, some VPN/security tools) silences event taps: detect, indicate, fall back to Carbon hotkeys for chords; the leader layer resumes when Secure Input ends.
- **Display wake/sleep races:** never apply profiles until the reconfiguration storm settles (debounce + screen-parameters stability check).

### 6.5 Persistence

`~/Library/Application Support/Zephr/state.json` (atomic writes, debounced 300 ms after changes): current trees, window fingerprints (bundle id, title hash, frame) for session matching, display profiles, and the last-known frame of every managed window — the crash-restore source. Config stays in `~/.config/zephr/config.toml` (XDG-style, dotfiles-friendly). Rules DB ships in the bundle with a user-overrides layer in the config.

### 6.6 Reliability engineering

- Exception/signal handlers restore all window frames from the snapshot before dying; relaunch offers "restore my layout."
- Uninstall (drag to Trash is detected on next login-item run; also an explicit menu action) unhides all apps and restores all frames.
- CI matrix: macOS 14/15/26 runners; the June developer-beta of each year's macOS gets a CI lane immediately (being usable on beta day-one is a recurring switcher trigger — see incumbents' September pain).
- Crash reporting opt-in only (no network calls otherwise; the app works fully offline).

### 6.7 Distribution

Developer ID signed + **notarized** from the first public build (explicit contrast with AeroSpace's stance — put the checkmark on the website). DMG + `brew install --cask` day one. Sparkle 2 with EdDSA-signed appcast, delta updates. Mac App Store: impossible for this category (AX control + event taps), documented in the FAQ so nobody wonders.

> **Status:** the pipeline is written and unrun. `just release` archives, exports with Developer ID, builds the DMG, and submits for notarization, and the app builds with Hardened Runtime on and App Sandbox off; none of it has been executed, because it needs an Apple Developer ID and `just notary-setup`. Sparkle, the appcast, and the Homebrew cask do not exist yet. Today's install path is build-from-source (`just app install`), which is exactly the friction §2 failure mode 1 is about - it is the last thing standing between this and a public build.

**License/source recommendation:** open-source core (MIT or GPL-3 — decide, see §11) to win the exact community that evangelizes these tools; the rules DB and importers live in the open repo to attract contributions. Monetization, if any, comes later and never gates the core manager (candidates: named layouts sync, team profiles). Flagged as an open question; the design does not depend on the answer.

---

## 7. Milestones

Phases, each with a hard exit criterion. No phase ships publicly before Phase 5.

- **P0 — Platform spike.** Prove: AX frame control across AppKit/Catalyst/Electron/Java apps; event-tap leader capture incl. Secure Input fallback; per-app actor timing. *Exit:* focus/move/resize across 10 mixed-toolkit windows, p95 < 50 ms; a hung test app provably cannot stall others.
- **P1 — Core tiling.** Tree engine + normalizations, auto-split placement, focus/move/resize, float toggle + structural float heuristics, direct chords, single workspace, menu-bar item, crash-snapshot restore. *Exit:* the team daily-drives it on one display for a week without reaching for Rectangle.
- **P2 — Workspaces & multi-monitor.** Stash engine + app-hide hybrid, per-display workspaces, workspace chords, rescue command, reconciliation audit, display migration (not yet profiles). *Exit:* one week of team dogfood with **zero lost-window incidents** (tracked); Mission Control screenshot review shows no stash artifacts for fully-stashed apps.
- **P3 — Discoverability.** Leader layer + command strip, palette, cheat sheet, onboarding flow + interactive tutorial, conflict scanner. *Exit:* 5 recruited testers who have never used a tiling WM each reach unaided tiling + workspace use in < 5 minutes; zero of them open documentation.
- **P4 — Config & rules.** Settings GUI, lossless TOML round-trip (with comment-preservation tests), shipped rules DB (≥50 apps), pick-a-window rule maker, AeroSpace importer + report, CLI + event subscriptions, doctor. *Exit:* an external AeroSpace user migrates their real config in < 10 minutes and keeps using Zephr the next day.
- **P5 — Signature features & launch hardening.** Display profiles + session restore, Sparkle, notarization pipeline, docs site, migration guides (from AeroSpace, yabai, Rectangle), beta program. *Exit:* the 50× dock/undock round-trip test passes with zero deviations; crash-free sessions > 99.5% across the beta cohort; then launch (Show HN + the r/unixporn-adjacent circuit + direct outreach to the authors of "I tried every Mac window manager" posts).
- **Post-1.0 (v1.1+):** named layouts with app launching; first-class native-tab nodes; scrolling (PaperWM/Niri-style) layout as an experimental per-workspace mode — there is visible demand and no good macOS answer; deeper bar-integration APIs.

---

## 8. Success metrics

- **Activation:** ≥ 80% of first launches reach first keyboard tile in < 2 minutes (local, anonymous, opt-in funnel — or measured via beta cohort studies if telemetry is rejected in §11).
- **The defaults metric:** ≥ 50% of week-4 retained users have never opened the config file *and* ≥ 30% have customized something — both camps served is the whole thesis.
- **Retention:** D30 ≥ 40% of activated users (category baseline is unknown; instrument via update-check uniques, which require no telemetry).
- **Reliability:** crash-free ≥ 99.7%; lost-window reports ≈ 0 (any report is a P1 bug by invariant).
- **Performance in the wild:** opt-in perf beacon p95s within §6.3 budgets.
- **Word of mouth (the actual goal):** unsolicited posts/reviews; "switched from AeroSpace/yabai" mentions; GitHub stars trajectory vs. AeroSpace's first year.

## 9. Non-goals

Explicitly out, to protect focus and the "never fights you" promise: controlling native macOS Spaces (no public API; the SIP trap); a status-bar replacement (integrate with SketchyBar instead); ricing beyond gaps/border/accent (no transparency engines, no shadows config); an embedded scripting language (the CLI + events cover it); Windows/Linux ports; AI features; any feature requiring SIP changes or persistent private-API use.

## 10. Risks

- **Apple sherlocks deeper tiling.** Likely direction of travel. Mitigation: our moat is the parts Apple won't build — workspaces, profiles, palette, per-app rules, CLI. Snapping was never the product.
- **AX behavior churn (every September).** Mitigation: reconciliation-first architecture absorbs event weirdness; beta-CI lane; public-API-only surface is the smallest possible breakage target.
- **Stash artifacts resist polish.** The corner approach has irreducible seams in edge arrangements. Mitigation: app-hide hybrid removes the common cases; rescue command bounds the damage; honesty in docs beats mystery.
- **i3 die-hards reject a leader-first identity.** Mitigation: direct chords are first-class and an i3 preset ships; the leader is the on-ramp, not a cage.
- **Electron heterogeneity** (a third of real-world windows). Mitigation: rules DB + AXEnhancedUserInterface handling + per-app degraded mode; test matrix includes VS Code, Slack, Chrome, Figma, Discord.
- **A solo-maintainer-shaped competitor ships our roadmap.** AeroSpace's planned refactor targets stability and tabs. Mitigation: our differentiation is product quality and onboarding, which is a posture, not a feature they can merge.

## 11. Open questions (need a decision, none block P0–P2)

1. ~~Name~~ — **decided: Zephr** (bundle id, socket path, config dir derive from it).
2. License and monetization posture (recommendation in §6.7: open core, decide before public beta).
3. Minimum macOS: 14 vs 15 (14 adds testing surface; usage data at beta should decide).
4. The single private-API escape hatch (§6.1): allowed behind a flag, or absolute zero?
5. Telemetry stance: fully off + beta-cohort studies, or opt-in anonymous funnel? (Default plan: fully off; measure via beta program.)
6. Default gaps on (8px) — validate with testers in P3; some switchers read gaps as "ricing."

---

## Appendix A — Terminology for implementers

**Leader / layer:** a key that opens a transient command mode with an on-screen key legend (the which-key pattern). **Tree / container:** i3's model — nested splits with orientation and per-container layout. **Accordion:** stacked layout where non-focused windows collapse to slivers (AeroSpace's tabs-analog). **Monocle:** focused window temporarily fills the workspace. **Stash:** off-screen holding position for windows in inactive virtual workspaces. **Reconciliation:** diffing the intended model against observed window reality and applying minimal corrections. **Display profile:** persisted layout state keyed by the fingerprint of connected displays.

## Appendix B — Default config file sketch (excerpt, for the doc site)

```toml
# ~/.config/zephr/config.toml — everything here is optional; these are the defaults.
leader = "alt-space"

[layout]
gaps = 8
focus-border = true
default = "tiles"        # tiles | accordion

[keys]                    # preset = "default" | "i3" | "aerospace" | "vim"
preset = "default"

[[rules]]
app = "com.apple.systempreferences"
action = "float"

[[rules]]
app = "us.zoom.xos"
title = "^zoom floating"
action = "float"

[callbacks]
on-workspace-changed = [] # e.g. ["sketchybar --trigger ws_change WS=$ZEPHR_WORKSPACE"]
```

> **Status:** the file actually written on first run is `ConfigFile.defaultText`, and this sketch is now behind it. Differences: the shipped file adds `menu-bar-icon`, `[layout] accordion-padding` and the commented `focus-border-color` / `-width` / `-radius` keys, a commented `[workspaces]` block (names plus `float-by-default`), and a commented `[[bind]]` example; and it comments the `[[rules]]` block out, because System Settings and Zoom's floating controls are already in the shipped rules database and writing them into the user's file would just duplicate it. `docs/config.html` is the reference that tracks the real file.
