# MacNotes

A tiny macOS utility: press **⌥ + .** (Option + Period) anywhere to toggle a floating,
always-on-top panel with your notes in it.

## Notes

The panel is [levihanlen.com/note](https://www.levihanlen.com/note) in its list layout, so it
holds the same notes as the site and the phone and syncs the way they do. The first time it
opens, enter the sync password in the page's settings; it is kept in this app's own web
storage, apart from any browser's.

- Click into a note to type into it. **Esc** leaves the note, closes the composer or a dialog,
  and otherwise hides the panel.
- **⌘N** opens the composer for a new note. **⌘F** goes to search. **⌘R** reloads.
- The page's own grid/list toggle works here too, and is remembered here.

Once the page has loaded, its notes are kept locally and stay readable with no connection. If
the panel can't reach the site when it starts, it tries again the next time it opens.

To point the panel at a dev server instead:

```sh
defaults write com.levihanlen.macnotes URL http://localhost:3000/note
```

`defaults delete com.levihanlen.macnotes URL` goes back to the site.

## Old notes

Before the panel moved to /note it kept one text file in
`~/Library/Application Support/MacNotes/`, with copies in `history/`. Nothing reads or writes
those any more. **Show Old Notes in Finder** in the menu bar item opens the folder so the text
can be pasted into /note.

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
- Links to other hosts open in your browser. Right-click → Inspect Element works in the
  panel for debugging the page.
- Window position/size is remembered.
- Quitting leaves the note being typed into first, so its last keystrokes are saved.
- Quit from the pencil icon in the menu bar.
