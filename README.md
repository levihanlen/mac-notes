# MacNotes

A tiny macOS utility: press **⌥ + .** (Option + Period) anywhere to toggle a floating,
always-on-top panel with your notes, or your KB board, in it. **⌘ + Space** opens a launcher for
apps, site pages, quick notes and kb cards.

## Notes and KB

The panel shows one of two pages, switched with **Notes | KB** in its title bar, **⌘1** and
**⌘2**, or the menu bar item. It opens on whichever was showing last, including after a
relaunch. Both pages stay loaded behind the switch, so switching is instant and each keeps its
scroll, its open dialog and anything half-typed.

**⌘R**, or **Reload** in the menu bar item, reloads both pages, not only the one showing. They
also reload on their own when the panel opens after 15 minutes or more put away, time asleep
included, so they catch up with the phone and the site without ⌘R. Not while the Mac is offline,
so the pages stay readable, and not a page with a dialog open, so a half-typed task isn't lost.
A note or the composer being typed into is saved first, as on quit.

## Notes

The panel is [levihanlen.com/note](https://www.levihanlen.com/note) in its list layout, so it
holds the same notes as the site and the phone and syncs the way they do. The first time it
opens, enter the sync password in the page's settings; it is kept in this app's own web
storage, apart from any browser's.

- Click into a note to type into it. **Esc** leaves the note, closes the composer or a dialog,
  and otherwise hides the panel.
- **⌘N** opens the composer for a new note. **⌘F** goes to search.
- The page's own grid/list toggle works here too, and is remembered here.

These shortcuts go to whichever page is showing. ⌘N presses the page's own **n**, which /kb
doesn't have yet, so on KB it does nothing; add a task from the board instead.

Once the page has loaded, its notes are kept locally and stay readable with no connection. If
the panel can't reach the site when it starts, it tries again the next time it opens on that
page.

## KB

The KB page is [levihanlen.com/kb](https://www.levihanlen.com/kb), the task board, in its
narrow one-column layout. It uses the same sync password as the notes, so once one is set up the
other is too. **⌘F** opens its task search and **Esc** closes it (and otherwise hides the panel).
Like the notes, it stays readable with no connection once it has loaded.

## Launcher (⌘Space)

**⌘Space** opens a second, smaller window high on the screen: one field that finds the Mac's apps
and the site's pages. It is [levihanlen.com/launcher](https://www.levihanlen.com/launcher), so the
searching lives on the site and this app only says which apps are installed and opens what's
picked.

- Type a few letters, **Enter** opens the top row, **↑/↓** move. What you pick often rises to the
  top, and with nothing typed the list is what you've opened lately.
- Apps open as from the Dock. Site pages open in your browser, except **note** and **kb**, which
  open this app's own panel.
- **n buy strings** adds a note to the top of the wall; **t call dentist** adds a card to /kb
  (short horizon, no parent). Both are pushed before the window closes. **note …** and **kb …**
  work too.
- **Esc**, or clicking anywhere else, puts it away. **Show Launcher** in the menu bar item opens it
  too.

Before ⌘Space works, turn off Spotlight's own shortcut: **System Settings → Keyboard → Keyboard
Shortcuts → Spotlight → Show Spotlight search**. Spotlight is still in the menu bar.

The page also asks this app for what only the Mac has:

- **brain/ search.** Notes in `~/Documents/GitHub/life-nextjs/brain` are searched on disk: a note
  matches when every word is in its path or its text, and notes named for the words come first.
  For a checkout somewhere else:
  `defaults write com.levihanlen.macnotes BrainPath ~/somewhere/brain`.
- **Commit.** Status, commit, pull and push go to the dev server's /git API on
  `http://localhost:3000` (or the `URL` default's origin, when that's a localhost one). The dev
  server has to be running.
- **Windows.** Moves the front app's window to a half, a third, two thirds, the whole screen, or
  the middle.
- **Notifications.** Clicking one opens its link. macOS asks to allow them the first time.

### Clipboard History

This app keeps the last 200 texts you copy, newest first, so the launcher can list them and put one
back. Copying the same text again moves it to the top. Text only, and nothing a password manager
marks as private. It lives in `~/Library/Application Support/MacNotes/clips.json`, readable only by
you, and is never sent anywhere. Delete the file to clear it.

Picking a clip puts it back on the clipboard and pastes it into the app you were in. Pasting and
moving windows press keys and move windows in other apps, so they need **System Settings → Privacy
& Security → Accessibility → MacNotes**; macOS prompts for it the first time. Without it, a picked
clip is only put back on the clipboard for **⌘V**, and windows don't move. Each `./build-app.sh`
makes a new signature, so after a rebuild remove MacNotes from that list (**−**) and add it again.

## Dev server

To point the panel at a dev server instead:

```sh
defaults write com.levihanlen.macnotes URL http://localhost:3000/note
```

KB and the launcher then come from the same origin, here `http://localhost:3000/kb` and
`http://localhost:3000/launcher`.
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

- Global hotkeys use the Carbon hotkey API, so they need no permission. Only pasting a clip and
  moving windows need Accessibility.
- The window is a non-activating floating panel: it stays on top, appears on every
  Space (including over full-screen apps), and doesn't steal focus from your current app.
- Links to other hosts open in your browser. Right-click → Inspect Element works in the
  panel for debugging the page.
- Window position/size is remembered.
- Quitting leaves the note being typed into first, so its last keystrokes are saved.
- Quit from the pencil icon in the menu bar.
