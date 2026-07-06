# MacNotes

A tiny macOS utility: press **⌥ + .** (Option + Period) anywhere to toggle a floating,
always-on-top plain-text scratchpad. Text is saved automatically and survives restarts.

## Build

```sh
./build-app.sh
```

This produces `MacNotes.app` in the repo root. Move it to `/Applications` if you like,
then launch it once. To have it start automatically, add it in
**System Settings → General → Login Items**.

## Details

- Global hotkey uses the Carbon hotkey API — no Accessibility permission needed.
- The window is a non-activating floating panel: it stays on top, appears on every
  Space (including over full-screen apps), and doesn't steal focus from your current app.
- Text autosaves (debounced) to `~/Library/Application Support/MacNotes/notes.txt`.
- Window position/size is remembered. Esc also hides the window.
- Quit from the pencil icon in the menu bar.
