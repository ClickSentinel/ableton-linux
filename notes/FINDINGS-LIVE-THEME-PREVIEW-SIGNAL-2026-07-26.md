# Findings: no external signal during Live's live theme preview (issue 35 point 4)

## Question

Issue 35 point 4: Live theme switching should apply in real time, not require
two Live restarts to commit. Patches 0050/0051 plus `theme_watch_loop` (see
`scripts/ableton-live`) already fix the "two restarts" part - the watcher
picks up a theme change as soon as `Preferences.cfg` is written and re-applies
`SetSysColors` immediately, no restart needed.

But a real remaining gap was observed directly: opening Preferences and
toggling the theme option updates the rest of Live's own UI (Skia-rendered)
immediately, live, while the dialog is still open - the win32u-drawn menu bar
chrome does not follow until the Preferences dialog is closed. Since
`Preferences.cfg` is only written on close, `theme_watch_loop` cannot react
any sooner than that: it fundamentally cannot see a change before the file
exists. The open question was whether Live emits *some other* observable
signal during the live-preview window - a different file, a registry write,
anything - that a watcher could hook into instead of `Preferences.cfg`,
to close this last gap.

## Method

With Live running normally (`~/.wine-ableton`, real daily-use prefix, real
license, real project), traced all file activity during a live theme-preview
window - opening Preferences, toggling the theme option back and forth
several times, without closing the dialog - via:

```
inotifywait -m -r --timefmt '%H:%M:%S' --format '%T %w%f %e' \
  ".../AppData/Roaming/Ableton/Live 12.4.3"
```

recursively covering the entire per-version AppData tree (Preferences,
Recorder, Templates, everything), not just `Preferences.cfg`. Registry state
(`~/.wine-ableton/{system,user}.reg`) was checked before and after the same
window via mtime, since a live in-memory registry write might not be
reflected in a file event depending on Wine's own flush timing.

## Result

Exactly one file event fired during the entire live-preview window:

```
Log.txt MODIFY
```

Checking the log content at that timestamp: it was a periodic "Service
Discovery: Init Gateway on Interface ..." message - Ableton Link's own
network discovery heartbeat, which fires on its own schedule regardless of
what the user is doing, coincidentally overlapping the test window. Nothing
in the log mentions the theme or color change itself.

`Preferences.cfg` itself: untouched for the entire live-preview window,
confirming the reported behavior - it only commits on dialog close.

Registry: `user.reg` (where an HKCU Ableton-specific value would land) was
untouched across the whole window. `system.reg` was touched, but a full
minute after the test window closed, and its timing didn't correlate with
any specific action taken during the test - consistent with Wine's own
periodic dirty-registry flush to disk, not something Ableton or the theme
toggle triggered.

## Conclusion

Live's own Settings UI is fully self-contained during live preview - it
repaints its own (Skia) widgets directly in process memory and does not
touch the filesystem, the registry, or emit any other externally observable
signal until the dialog is closed and the setting is committed. There is
no alternative file, registry key, or log signature to switch a watcher to;
`Preferences.cfg` is not just the easiest signal to watch, it is the *only*
one that exists.

Practical consequence: `theme_watch_loop`'s current approach (react to
`Preferences.cfg` the instant it's written, whether via inotify or a poll)
is already at the ceiling of what's reachable without Live itself exposing
something new. The remaining delay - the time the Preferences dialog is
open - is not a watcher-implementation problem and can't be shortened by a
smarter watcher; closing it fully would need Live to expose a live/IPC
signal, which is out of this project's control (closed-source app). Issue
35 point 4 should be considered addressed within that constraint, not left
open pending a better watcher.
