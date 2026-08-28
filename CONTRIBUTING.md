# Zephr

A keyboard-driven tiling window manager for macOS. The product spec lives in
`docs/DESIGN.md` — read it before making design decisions; its three
invariants (never lose a window, never require reduced security, never stall)
override everything else, and §-references in code comments point into it.

## Build & test

- `just` lists all recipes: `just test` (Core suite), `just run` (build +
  launch), `just app dmg` (dev-signed DMG), `just release` (archive →
  Developer ID export → DMG → notarize; needs `just notary-setup` once).
- Without just: `cd ZephrCore && swift test` and
  `xcodebuild -project Zephr.xcodeproj -scheme Zephr build`.
- Running the app requires the Accessibility permission (granted via the
  first-run window). Rebuilds under ad-hoc signing may require re-granting.

## Architecture

- `ZephrCore/` — pure Swift package (zero AppKit): i3-style tree
  (`TreeNode`, `Workspace`), multi-display model (`WorkspaceModel`), layout
  solver (`Solver`), off-screen stash geometry (`StashPlanner`), per-app
  rules (`Rules`), command vocabulary (`Command`). All geometry is global CG
  coordinates (top-left origin, y-down); AppKit rects are converted at the
  boundary with `cocoaToGlobal`.
- `Zephr/` — the app (files are auto-included via the Xcode synchronized
  group; no pbxproj edits needed for new files):
  - `Services/AppAXConnection.swift` — one actor per target app on its own
    dispatch queue; ALL AX calls for a pid go through it (anti-stall, §6.3).
  - `Services/ObserverHub.swift` — AXObserver notifications → engine events.
  - `Services/HotkeyService.swift` — CGEvent tap, ⌃⌥ chords, leader layer.
  - `Engine/TilingEngine.swift` — MainActor orchestrator; the ZephrCore
    model is the source of truth, reality is reconciled against it (§6.4).
  - `UI/` — command strip HUD, permission gate; `ZephrApp.swift` menu bar.

## Conventions

- Swift 6 strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in
  the app target. AX tokens travel as `AXElement` (@unchecked Sendable);
  messaging through them only on the owning `AppAXConnection`.
- App Sandbox must stay OFF (the AX API cannot control other apps from a
  sandboxed process). Public APIs only — no private AX/SkyLight calls, ever.
- Every model mutation goes through `Workspace`/`WorkspaceModel` so
  normalization and the window index stay consistent; `Workspace.validate()`
  is the invariant checker the property tests lean on.

## Status (August 2026)

Implemented: P0–P2 foundations; config file with defaults written on first
run + hot reload (`ConfigFile` in Core, `ConfigService` in app — interim
parser, P4 brings the lossless TOML engine); leader layer + command strip +
cheat sheet; palette (⌃⌥P); display profiles + session restore
(`ProfileEngine`); focus border; onboarding flow with leader picker and
interactive tutorial; doctor (Stage Manager, rivals, Secure Input); IPC
socket + `tools/zephrctl`; single-instance takeover; activity-gated audit
(battery); CI workflow.

Daily-driver batch: close window (leader q / ⌃⌥Q), workspace back-and-forth
(re-press the current number), pause/resume (menu + palette + zephrctl —
releases all windows and the keyboard), config `action = "workspace N"`
rules, `[workspaces]` names + float-by-default, AX-revocation detection in
the audit, rival-WM warning at launch, onboarding login toggle.

Also implemented: Settings window (targeted config writeback preserving
comments — the line surgery is `ConfigEdit` in Core, pure and unit-tested;
`ConfigService` is file IO and hot reload only), key presets
(default ⌃⌥ / i3 ⌘⌥ / aerospace ⌥ / vim leader-only), AeroSpace + Amethyst
importers with plain-language report (`AeroSpaceImport` in Core),
drag drop-zones (`retile`), gap drag-resize (`dragResize` + invisible
strips), `zephrctl subscribe` event stream, progressive chord hints.

Gap-closing batch: native-fullscreen lifecycle (unmanage on enter, re-tile
on exit, palette-listed ⛶), Carbon hotkey fallback under Secure Input,
layer one-shot + idle timeout (`[keys] one-shot` / `layer-timeout`),
`dock-icon` setting, "did you mean" config suggestions, veto-float rule
learning persisted to config, tutorial practice windows (self-managed via
title prefix), per-display menu indicator ("3·1"), Settings Workspaces +
Profiles tabs, full zephrctl coverage + `doctor` JSON, os_signpost perf
intervals, uncaught-exception restore.

Audit wave (Aug 2026): focus-path repair centralised in
`Workspace.normalize()`; `ConfigEdit` extracted with round-trip tests;
learned float rules are per-app and no longer anchored to a live window
title; `zephrctl` replies half-close so the CLI returns; auto-repeat no
longer leaks swallowed chords into the focused app; crash recovery runs off
the MainActor; workspace ids stay in 1–9 and redock returns them to their
own display (`Workspace.preferredDisplay`); ⌘H withdraws an app's windows
like a minimize; focus sets `kAXFrontmost` and verifies with one retry.

Known gaps, ranked (see the PR that landed the audit wave for detail):
Zephr is **not Space-aware** — it manages every window AX reports, including
windows on another native Space, so mixing Spaces with Zephr workspaces
leaves empty-looking tiles; ~27 uncoalesced `applyAll()` sites reflow the
desktop repeatedly at startup; per-pid frame batches can apply out of order
because separate tasks reach an actor unordered.

Not yet built (by design or needs credentials): Sparkle + notarization
pipeline (needs an Apple Developer ID + hosted appcast), lossless TOML
document engine (current writeback is line-targeted, full P4 item),
first-class native-tab nodes / named layouts / scrolling layout (post-1.0
per §7), arbitrary per-key rebinding beyond presets, the onboarding
screen-recording asset (§4.1 — needs a real recording), frame-write
animation (AX cannot animate; instant is Reduce-Motion-correct).
