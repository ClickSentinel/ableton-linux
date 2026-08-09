# Ableton Live shortcut research

This record preserves the shortcut audit completed on 2026-08-06. It contains
the detailed evidence and the open test cases behind the current
[shortcut support guide](ABLETON-WINE-SHORTCUT-PARITY.md). It is a research
record. The guide describes the current implementation.

The audit started after Mike Verdone (Ableton) reported that on Windows,
Alt+4 focuses the device chain and nothing else, while under Wine the same
press also arms the menu bar, so the next typed letter opens a main menu.
This note audits every documented Live shortcut against every key combination
Wine itself intercepts, records the root cause of the reported bug with a
reproducer, and lists the collisions that belong to the desktop environment
rather than to Wine.

Sources, all fetched 2026-08-06:

- Live 12 manual, chapter 41 "Live Keyboard Shortcuts" (complete) and
  chapter 40 "Accessibility and Keyboard Navigation".
- Live 11 manual, "Live Keyboard Shortcuts" chapter.
- Wine source before the fix: base `5c23dd1c` and upstream
  `wine-mirror/wine` master. The cited functions were identical on this date.
  Patch 0070 changes the two functions described in section 2.

## 1. Wine keyboard handling

Two layers act on keys before or beside the application.

### DefWindowProc (`dlls/win32u/defwnd.c`)

Runs only for messages the application passes through.

| Key | Behavior | Site |
|---|---|---|
| Alt pressed and released alone | `WM_SYSCOMMAND SC_KEYMENU 0`: menu bar enters keyboard mode | defwnd.c:2792 |
| F10 pressed and released alone | same as Alt alone | defwnd.c:2761, 2796 |
| Alt+letter (`WM_SYSCHAR`) | `SC_KEYMENU <char>`: mnemonic search; a match opens that menu, no match beeps and ends immediately | defwnd.c:2801, menu.c:4631 |
| Alt+Tab, Alt+Esc | explicitly excluded from the mnemonic path | defwnd.c:2817 |
| Alt+Space | `SC_KEYMENU ' '`: system menu | defwnd.c:2818, menu.c:4615 |
| Alt+F4 | `SC_CLOSE` posted to the root window | defwnd.c:2775 |
| Shift+F10 | `WM_CONTEXTMENU` | defwnd.c:2784 |
| Shift+Esc | `SC_KEYMENU ' '`: system menu | defwnd.c:2788 |
| Enter while minimized | `SC_RESTORE` | defwnd.c:2803 |

The bookkeeping for "Alt (or F10) was pressed and released without another
key" lives in two file-scope statics, `menu_sys_key` and `f10_key`
(defwnd.c:41). They change only when key messages actually reach
DefWindowProc. That is the root cause of the reported bug; see section 2.

### Message retrieval (`dlls/win32u/message.c`, `process_keyboard_message`)

Runs for every hardware key message a thread retrieves, whether or not the
window procedure later swallows it.

| Key | Behavior | Site |
|---|---|---|
| F1 keydown | posts `WM_KEYF1`, which DefWindowProc turns into `WM_HELP` | message.c:2527 |
| Menu key (`VK_APPS`) keyup | posts `WM_CONTEXTMENU` | message.c:2542 |
| Browser and media keys | `WM_APPCOMMAND` | message.c:2531 |

### winex11 (`dlls/winex11.drv/keyboard.c`)

Wine grabs no keys from X. One mapping difference matters: AltGr
(`ISO_Level3_Shift`) is delivered as plain right Alt, scancode 0x138
(keyboard.c:122, 200). Real Windows synthesizes Ctrl+Alt for AltGr.
Character translation still uses the AltGr state (keyboard.c:1569), so
typing `{`, `@`, `[` works, but an application that inspects modifier state
during AltGr sees Alt down where Windows shows Ctrl+Alt down. Consequence
for Live on AltGr layouts: a chord like AltGr+7 can read as Alt+7 (Move
Focus to the Learn View) where Windows would read Ctrl+Alt+7 (Hide/Show the
Learn View). Not yet verified in Live; see the matrix in section 5.

## 2. Confirmed defect: every handled Alt chord arms the menu bar

### Mechanism

Windows tracks "another key went down while Alt was held" in the input
queue (the win32k queue flags `QF_FMENUSTATUS` and `QF_FMENUSTATUSBREAK`,
as also implemented by ReactOS), on the raw input path. An application
swallowing the messages cannot corrupt that state.

Wine tracks the same state in `menu_sys_key`, updated only inside
DefWindowProc. Live handles its Alt shortcuts itself and never forwards
them, so:

1. Alt down. Live has no use for it, passes it through, DefWindowProc sets
   `menu_sys_key = 1` (defwnd.c:2768).
2. 4 down, and the `WM_SYSCHAR` for it. Live focuses the Device View and
   swallows both. The flag keeps its value.
3. Alt up. DefWindowProc sees `menu_sys_key == 1` and sends
   `WM_SYSCOMMAND SC_KEYMENU 0` (defwnd.c:2795). `track_keyboard_menu_bar`
   with a zero char selects the first menu item and stays in keyboard
   tracking mode (menu.c:4643). The next typed letter is a mnemonic and
   opens that menu. This is exactly the reported symptom.

Release order does not matter. If Alt goes up before the 4, the
`SC_KEYMENU` fires before the digit's keyup could have cleared the flag, so
the bug is not avoidable from the application side.

### Reproducer

`tools/altnum-menu-repro.c`. A plain Win32 window with a File/Edit menu bar
whose window procedure swallows Alt+4 the way Live does (`swallow` mode) or
passes everything through (`pass` mode), then injects the chords with
`SendInput`. `SendInput` enters the same server input queue and
`process_keyboard_message` path as X11 input. The test needs a working Wine
display, but it does not depend on physical keyboard input.

Observed 2026-08-06 under wine-staging 11.13 (system wine; the involved
code is byte-identical in our tree and upstream master):

    swallow mode, inject Alt down, 4 down, 4 up, Alt up:
      WM_SYSKEYDOWN 12, WM_SYSKEYDOWN 34 (swallowed), WM_SYSCHAR 34 (swallowed)
      WM_KEYUP 12
      WM_SYSCOMMAND SC_KEYMENU ch=00
      WM_ENTERMENULOOP          <- menu mode entered on Alt release
    inject F:
      WM_INITMENUPOPUP          <- the File menu opens

    pass mode, same chord:
      WM_SYSCHAR 34 -> SC_KEYMENU ch=34 -> beep, menu loop enters and
      exits in the same tick, no lingering state. F arrives as a plain
      keydown. This matches Windows for an unhandled Alt chord.

Build and run. Each mode now checks its own result and returns an error if a
required result fails:

    winegcc -o altnum-menu-repro tools/altnum-menu-repro.c
    wine ./altnum-menu-repro.exe swallow   # Live-like path
    wine ./altnum-menu-repro.exe pass      # normal menu path

### Affected Live shortcuts (all fire the same staleness)

Every keyboard shortcut Live handles that contains Alt:

- Live 12 focus family: Alt+0 through Alt+8, AltShiftP (manual 41.2, 40.4).
  Alt+4 is the reported case.
- Clip View tabs: AltShift1, AltShift2, AltShift3 (41.10).
- Arrangement: AltU, Alt+ and Alt-, AltShiftM (41.16), ShiftAltT (41.17).
- Live 11: Alt1, Alt2, Alt3 switch Clip View tabs.

Mouse chords have the same exposure through the same statics: DefWindowProc
clears the flag on button-down (defwnd.c:2758) but Live swallows its
clicks, so Alt+click and Alt+drag gestures (device activator toggle,
velocity drag, curved automation, breakpoint select, 41.4/41.7/41.12)
should also arm the menu bar when Alt is released. Expected from the code,
not yet observed in Live; in the matrix.

Not affected, and any fix must keep them working:

- Alt+F, Alt+E, Alt+C, Alt+V, Alt+N, Alt+O, Alt+H open Live's menus by
  mnemonic (41.28). Live forwards unrecognized Alt letters, the
  `WM_SYSCHAR` path finds the match, the menu opens. Mike confirms this
  works and it matches Windows.
- Shift+F10 and the Menu key open Live's context menu (41.29). Both paths
  work today (defwnd.c:2784, message.c:2542).
- Alt+F4 closes, Alt alone arms the menu bar, F10 alone would if Live did
  not bind it. Alt alone arming the bar is correct Windows behavior.

### Fix: patch 0070 (this branch, repro-verified 2026-08-06)

`patches/0070-win32u-break-alt-f10-menu-arming-on-consumed-keys.patch`.
Keeps the arming logic where it is and moves the disarming to where
Windows does it: the input retrieval path. defwnd.c exports
`cancel_menu_key_state()`; `process_keyboard_message` calls it for every
removed keydown other than Alt itself, and `process_mouse_message` for
every removed button-down. Both run whether or not the window procedure
later consumes the message, and both already carry side effects of this
kind (F1, VK_APPS, appcommand keys), restoring the win32k queue-flag
semantics. Behavior for pass-through applications is unchanged.

Verified against a complete patched build of the 11.13 tree. The test ran on
a headless display on 2026-08-06:

- swallow mode, both release orders: no `SC_KEYMENU`, no
  `WM_ENTERMENULOOP`, the follow-up F opens nothing. Bug gone.
- Alt+F mnemonic: `SC_KEYMENU ch=66`, `WM_ENTERMENULOOP`,
  `WM_INITMENUPOPUP`. The File menu still opens.
- bare Alt press and release: `SC_KEYMENU ch=00`, menu bar arms, Esc
  leaves. Preserved.
- pass mode: identical to the unpatched run, including the transient
  beep path for an unhandled Alt+4.

Full-series apply check passed: pristine `wine-base-5c23dd1c` extraction,
all 65 patches applied with the container-build.sh logic, 0070 lands
clean on top. build-audit.sh carries the 0070 STAMP_ONLY entry and
SERIES.sha256 is refrozen. Not yet run against real Live; the matrix in
section 5 stays open until then.

F10 stays symmetric: Live swallows its F10 keydown (Back to Arrangement),
so `f10_key` never arms and there is no F10 variant of the bug today.

Upstream master has the same defect, so the patch is an upstreaming
candidate. 0066 through 0068 are reserved by PR 124 and other branches
also claim 0070 and up; renumber at merge time as usual.

## 3. Full shortcut audit

Classes:

- A: broken under Wine, the section 2 defect. Listed above in full.
- B: intercepted by Wine on purpose, matches Windows. Listed above.
- C: no Wine interception, expected to work. The bulk of chapter 41:
  every Ctrl and Ctrl+Shift chord, every plain letter and digit, F-keys,
  arrows, Home/End, PageUp/Down, Tab families, Esc, Space, Enter, Delete.
  Two notes. F1 (Activate Track 1) additionally posts `WM_KEYF1` from the
  retrieval path; harmless unless Live reacts to `WM_HELP`, watch for a
  help side effect on F1. Chapter 41's Windows column never uses the Win
  key, so Super stays free for the desktop.
- D: stolen by the desktop environment before Wine sees the key.
  Environment configuration, not Wine defects. Section 4.
- E: layout divergence, the AltGr mapping in section 1. Affects AltGr
  layouts (German, French, Nordic and others) in unverified ways.

Chapter 41 sections with only class C entries, audited and unremarkable:
41.3 sets, 41.5 editing, 41.6 values, 41.8 loop markers, 41.11 sample
editor, 41.13 grid, 41.14 quantization, 41.15 Session View, 41.19 tracks,
41.20 transport, 41.21 audio engine, 41.22 browser, 41.23 similarity,
41.24 key/MIDI map. Sections contributing class A rows: 41.1 (Alt view
toggle click), 41.2, 41.4, 41.7, 41.10, 41.12, 41.16, 41.17. Class B rows:
41.28, 41.29. Live 11 deltas: Alt1/2/3 (class A), CtrlAltL and ShiftF12
detail view (C), CtrlAltDelete delete fades (D below; Live 12 moved it to
CtrlAltBackspace, which is safe since X server zap defaults off).

## 4. Desktop environment collisions (class D)

The compositor consumes these before Wine sees them. Windows parity is the
bar, so each needs either a documented remedy or nothing if Windows loses
the same key (Alt+Tab).

| Live binding | Action | Collides with | Verified |
|---|---|---|---|
| CtrlAlt Up/Down | Adjust Note Selection Chance (41.12) | GNOME workspace switch, bound by default | yes, gsettings on this machine, 2026-08-06 |
| CtrlAlt Left/Right | (Live: none today) | GNOME workspace switch | yes, same |
| CtrlAltT | Insert Return Track | Ubuntu GNOME terminal binding; vanilla GNOME leaves it unbound | vanilla: unbound here |
| CtrlAltDelete | Live 11 delete fades | GNOME power/logout dialog | known default, unverified here |
| Alt+Space | Windows system menu | window menu on several DEs; unbound on this GNOME | Live does not bind it; cosmetic |
| Alt+1..8 | Live 12 focus family | common user configs on i3/sway/Hyprland bind Alt+digits to workspaces | config-dependent |
| Alt+drag | velocity drag, envelope curve and other gestures | window-move modifier. GNOME defaults to Super (verified here); KDE ships Alt on many versions | KDE unverified |
| Alt+Tab | (not a Live binding) | window switcher | same loss as Windows, no action |

Remedy text for users belongs in TROUBLESHOOTING once the class A fix
ships, so one entry can cover both: what Wine now fixes, what the DE still
owns, and the rebind/settings pointer per DE. Not written yet; release
names, not patch numbers, when it is. Takeover mechanisms for GNOME are
reviewed in section 7.

## 5. Verification matrix (open)

All on our runtime with production prefix and launcher, per the usual
standard. Nothing below has been run against real Live yet.

| Check | Version | Expected |
|---|---|---|
| Alt+4, then type a letter | 12 | bug reproduces pre-fix; post-fix: focus moves, menu stays dark |
| Alt+0..8, AltShiftP, AltShift1..3, AltU, AltShiftM, ShiftAltT, Alt+/- | 12 | same |
| Alt1/2/3 | 11 | same |
| Alt+F E C V N O H | both | menu opens, before and after fix |
| Shift+F10, Menu key | both | context menu, unchanged |
| F10 | both | Back to Arrangement, no menu arm |
| F1 | both | track 1 toggle, watch for a help side effect |
| Alt+drag velocity, Alt+click device activator, release Alt | 12 | pre-fix: expect menu arm (unobserved); post-fix: none |
| Esc during armed menu | both | leaves menu mode (verified in repro) |
| AltGr chords on a German layout | both | record actual vs Windows behavior, class E |
| CtrlAlt Up/Down in MIDI editor on GNOME | 12 | stolen by GNOME, document remedy |

## 6. Repro artifacts

- `tools/altnum-menu-repro.c`, this branch.
- Raw logs: scratch only (`swallow.log`, `pass.log`, session scratchpad),
  transcribed in section 2.

## 7. GNOME shortcut control review (2026-08-06)

This section records the options reviewed before the launcher was complete.
The current code uses the method in 7a, but it changes only the exact Up,
Down, and Live 11 Delete entries. The other options are not in the code.

GNOME consumes CtrlAlt+arrows
(workspace switch) and CtrlAlt+Delete (logout dialog, collides with Live
11 delete fades) before Wine sees them, so patch 0070 cannot help; the
compositor owns these keys. Four routes, in order of usefulness. All
schema facts below were read from gsettings on a GNOME Wayland session
(CachyOS, 2026-08-06); bindings apply immediately on change, verified by
a live strip-and-restore round trip.

### 7a. Launcher-managed gsettings override (recommended)

GNOME has no per-application shortcut exceptions, but bindings are plain
gsettings keys that take effect immediately. The launcher can hold them
for the session the same way it already holds the performance power
profile: save, strip, restore on exit.

The initial proposal included these keys:

    org.gnome.desktop.wm.keybindings switch-to-workspace-up      -> []
    org.gnome.desktop.wm.keybindings switch-to-workspace-down    -> []
    org.gnome.desktop.wm.keybindings switch-to-workspace-left    -> keep only non-CtrlAlt entries
    org.gnome.desktop.wm.keybindings switch-to-workspace-right   -> keep only non-CtrlAlt entries
    org.gnome.settings-daemon.plugins.media-keys logout          -> [] (Live 11 sessions)

On this machine up/down carry only the CtrlAlt binding (strip to empty),
left/right also carry Super variants, which stay. Super combinations
never collide: chapter 41's Windows column does not use the Win key.

Shape:

- Save the exact current value of each key to a state file before
  changing anything; write the stripped value; restore from the state
  file on exit through the launcher's exit path.
- Crash guard: if the state file already exists at launch, restore it
  first, then proceed. The state file holds the pre-Live values, so a
  crashed session heals on the next start.
- Second-instance guard: skip the save step when the state file exists
  (the restore-first rule already covers it); restore only when the last
  instance exits, or accept last-exit-wins for simplicity.
- Scope: only when the session is GNOME (XDG_CURRENT_DESKTOP) and the
  schema keys exist. KDE has its own mechanism (kwriteconfig kglobalshortcutsrc);
  out of scope here.
- Opt-in flag, not default: silently editing a user's desktop bindings
  is surprising, and the stripped keys stay dead for every other window
  while Live runs. Naming and default are Theo's call.

Tested on this machine: setting switch-to-workspace-up to [] and back
restores the original literal exactly, effective immediately, no session
restart.

### 7b. Mutter Xwayland grab whitelist (fullscreen mode, needs a fork patch)

Mutter supports full shortcut takeover for X11 clients: when a client
holds an active X keyboard grab and its WM_CLASS matches
`org.gnome.mutter.wayland xwayland-grab-access-rules` (wildcards
supported, "!" denies), all keys route to the client. The user breaks a
grab with `org.gnome.mutter.wayland.keybindings restore-shortcuts`,
default Super+Escape. The default allow list ships with virt-viewer,
gnome-boxes and friends; this is the mechanism VM viewers use.

Wine never issues XGrabKeyboard: the winex11 GrabFullscreen option clips
the pointer only, and the only XGrabKeyboard in the tree is a comment
(keyboard.c:1414). Using this route means a fork patch that grabs the
keyboard while a launcher-selected fullscreen window holds focus, paired
with 0065's fullscreen normalization, plus a setup step that adds Live's
WM_CLASS to the access rules. Takeover would then cover everything,
including Alt+Tab and Super, which is more than Windows parity and wrong
for windowed use. Candidate for a fullscreen performance mode later, not
for the default session.

### 7c. Wayland shortcuts inhibitor (future, driver change)

The `zwp_keyboard_shortcuts_inhibit` protocol is the native Wayland form
of 7b and needs the winewayland driver, which our stack does not use
(winex11 under XWayland). Becomes relevant only if the fork ever moves
drivers.

### 7d. Documentation only (fallback, always available)

One-time user commands, global rather than session-scoped: remove the
CtrlAlt variants from the workspace bindings (left/right keep their
Super bindings; up/down lose their only binding) and clear or rebind
logout for Live 11 users. This is the TROUBLESHOOTING content once this
work is documented; per the docs spec it names releases, not patches,
and stays in the reader's chair.

Recommendation: implement 7a in the launcher behind an opt-in flag, ship
7d as the documented remedy for everyone else, keep 7b as a fullscreen
mode idea, ignore 7c until the driver changes.
