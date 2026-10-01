# Cascade

A menu bar utility that arranges windows in a classic Windows-style cascade: every window gets the
same size and is offset diagonally so its title bar and left edge stay visible and clickable.
Windows are grouped by application, and the window that was in front stays on top.

## Install

```bash
./install.sh
```

Builds a universal `Cascade.app`, copies it to `/Applications`, and launches it. On first run, grant
**Accessibility** access (System Settings → Privacy & Security → Accessibility) — macOS requires it
to move other apps' windows. Re-running `install.sh` produces a new ad-hoc signature, so it resets
the grant and you'll need to enable it again.

## Use

| Action | Shortcut | Menu |
| --- | --- | --- |
| Cascade visible windows | ⌃⌥C | Cascade Visible Windows |
| Cascade all windows, restoring minimized windows and hidden apps | ⌃⌥⇧C | Cascade All Windows (incl. Minimized) |

The cascade goes on the display under the mouse pointer. The menu also has **Launch at Login**.

## Notes

- Only standard windows on the current Space are arranged; full-screen windows, panels and dialogs are skipped.
- Window size shrinks as the stack grows (down to ~55% of the screen); past ~17 windows the cascade
  wraps back to the top-left, like Windows did.
- Tunables (step size, minimum window size) are constants in `CascadeLayout` in `Sources/main.swift`.
