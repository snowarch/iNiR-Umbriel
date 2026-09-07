# iNiR-Umbriel

iNiR compatibility work for the [Umbriel](https://github.com/noctalia-dev/umbriel) Wayland compositor.

> **Status:** experimental port, not a complete or stable compatibility target yet. This repository tracks only the Umbriel work. The established Niri edition remains in [snowarch/iNiR](https://github.com/snowarch/iNiR) and is maintained separately.

**Last reviewed:** 2026-09-06
**Current checkpoint:** `49fff518`

**Verified locally after that checkpoint:** no uncommitted compatibility changes; the checks below describe the current tree.

## What works today

- Native Umbriel session lifecycle through `umbriel-session.target`
- Umbriel IPC backend for windows, workspaces, overview, keyboard layouts and compositor actions
- Ported keybinds with explicit handling for Umbriel-only differences
- Native scratchpads and exact window restore by foreign-toplevel ID
- Native Umbriel output and foreign-toplevel capture through the compositor protocols exposed to `grim`
- Settings integration for input, scrolling/dwindle/master layouts, appearance, animations and scratchpads
- Safe display configuration previews with external systemd rollback
- Output policies for VRR, tearing, direct scanout and HDR
- Managed Umbriel window rules with validation and rollback
- Fullscreen/GameMode state sourced from Umbriel rather than Niri geometry heuristics
- Umbriel-aware autostart, setup, doctor, service wiring and Arch/CachyOS dependency handling
- Umbriel-aware status/logs/update/repair diagnostics, migration scoping and update checks
- Shared AltSwitcher, Waffle Task View and WorkspaceStrip using the compositor-neutral window/workspace model
- Compositor-neutral cached window previews, using exact Umbriel foreign-toplevel captures without touching the clipboard
- Semantic `inir` IPC and screenshot commands recover the active compositor session when invoked from a TTY/support shell
- Native `wf-recorder` capture resolves the focused Umbriel output correctly
- Idle/DPMS, hibernate monitor power, logout and shared media/output routing use compositor-aware session state
- Shared keyboard layout, taskbar, widget power and per-monitor workspace consumers use the compositor-neutral model
- Region capture, OCR and recording run under Umbriel; snap-to-window remains disabled until Umbriel exposes viewport-local window geometry
- Umbriel desktop portal is installed/repaired explicitly on Arch/CachyOS and checked by Doctor

This list describes implemented and tested paths only. Other iNiR surfaces may still contain Niri-specific assumptions or may not have been validated under Umbriel yet.

## Install / test

Arch/CachyOS is the currently tested automated dependency path.

```bash
git clone https://github.com/snowarch/iNiR-Umbriel.git
cd iNiR-Umbriel
./setup install
```

The installer detects installed/active supported compositors and asks which target to prepare. To select Umbriel explicitly:

```bash
./setup install --compositor umbriel
```

Then log out, select **Umbriel** in the display manager and log back in.

Useful checks:

```bash
inir status
inir doctor
inir logs
umbriel validate -c ~/.config/umbriel/config.toml
```

Update the checkout with:

```bash
inir update
```

On Fedora, Debian/Ubuntu and generic distributions, Umbriel dependency installation is not automated yet. Install Umbriel and its required runtime dependencies yourself, then use:

```bash
./setup install --compositor umbriel --skip-deps
```

## Roadmap

Near-term work is focused on correctness before claiming broad compatibility:

- Audit every `inir` setup/install/update/status/logs/doctor/recovery path under Umbriel
- Remove or capability-gate remaining Niri-only assumptions in shared shell surfaces
- Expand native Umbriel workspace, window-rule, output and presentation-policy support
- Continue porting shared window/overview consumers while keeping Orbit and arbitrary move-by-ID Niri-only until Umbriel exposes equivalent semantics
- Improve multi-output configuration and safe rollback UX
- Validate fresh installs and updates from this repository rather than development worktrees
- Extend distro installation support only where Umbriel packaging can be handled correctly

The README will be updated as support is verified. Features are not considered supported here merely because they work in the Niri edition.

---

Compatibility work for **iNiR-Umbriel is currently being implemented and maintained with explicit AI assistance**, including code changes, runtime validation and compatibility auditing under maintainer supervision.
