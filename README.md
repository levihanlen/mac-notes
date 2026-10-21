# MacNotes

A tiny macOS utility: press **⌥ + .** (Option + Period) anywhere to toggle a floating,
always-on-top plain-text scratchpad. Text is saved automatically and survives restarts.

## Notes

Everything is one scrolling document. A line that's exactly `---` splits it into notes
and is drawn as a thin rule (the dashes show again while the cursor is on that line).
A note's title is its first line.

- **⌘N** starts a new note at the top.
- The strip on the right has one segment per note. Hover it to see every note's title;
  click one to jump there.
- Hover a note to get a copy button for just that note (or **⇧⌘C** for the note the
  cursor is in). The title-bar copy button (or **⌥⌘C**) copies everything.
- **⌘F** finds, **⌘G** / **⇧⌘G** go to the next / previous match.

## History

Every time the window hides, every 5 minutes while you type, and before any big deletion,
a copy of your notes goes into `~/Library/Application Support/MacNotes/history/`.
Everything from the last day is kept, then one per hour for a week, then one per day
forever. The clock button in the title bar lists recent copies; pick one to open it.

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
  If that file can't be read, it's copied into `history/` before anything is saved over it.
- Window position/size is remembered. Esc also hides the window.
- Quit from the pencil icon in the menu bar.
