# Ableton Live shortcut support

This note explains the shortcut conflicts that can affect Live and the
mitigation for each one.

Two systems can interfere with a shortcut:

- Wine can receive an Alt shortcut but mistake it for an Alt press by itself.
- GNOME can take a Ctrl+Alt shortcut before Wine receives it.

These problems can look similar in Live, but they have different causes. The
Wine mitigation is automatic. The GNOME mitigation is optional because it
temporarily changes shortcuts for the complete desktop session.

## Wine Alt handling

Live handles many Alt shortcuts inside the application. Alt+4 moves focus to
the device chain, for example, and Live also uses Alt with mouse actions.

Earlier Wine menu handling did not always record the key or click that Live
handled between the Alt press and the Alt release. Wine could then treat the
complete shortcut as Alt by itself. This selected the menu bar, and the next
letter could open a menu instead of going to Live.

### Wine mitigation

Wine now clears a pending menu action when it receives another key press or a
mouse click. It does this before Live handles that input. The result does not
depend on whether Live passes the input to the normal Windows menu code.

An Alt shortcut that Live handles now performs only its Live action. It does
not prepare the menu for the next letter.

Normal menu controls keep their usual behavior:

- Alt by itself selects the menu bar.
- Alt with a menu letter opens that menu.
- F10 controls the menu when the application does not use F10 itself.
- An application can pass an unhandled Alt shortcut to Windows menu handling.

The patched Wine runtime applies this mitigation for every launch. It does not
need a launcher option.

## GNOME shortcut ownership

GNOME uses Ctrl+Alt+Up and Ctrl+Alt+Down to change workspaces. Live uses the
same keys to adjust note selection chance. GNOME also uses Ctrl+Alt+Delete for
logout, while Live 11 uses that shortcut to delete fades.

GNOME handles these keys before Wine. Wine cannot send a key to Live after the
desktop has already used it, so this conflict needs a desktop-level mitigation.

### GNOME mitigation

Start Live with this command when you want Live to receive the conflicting
keys:

```bash
ABLETON_SHORTCUTS=take ableton-live
```

The launcher temporarily holds only these GNOME shortcuts:

- Ctrl+Alt+Up
- Ctrl+Alt+Down
- Ctrl+Alt+Delete for Live 11 only

The launcher removes only an exact Ctrl+Alt+Up, Ctrl+Alt+Down, or
Ctrl+Alt+Delete entry from the related GNOME setting. It keeps entries with
another key or another modifier. For example, Ctrl+Alt+Shift+Up,
Ctrl+Alt+Page Up, and shortcuts that use the Super key stay in place.

This mitigation affects the complete GNOME session. While Live runs, the held
keys cannot change a workspace or open the logout dialog in another
application. For this reason, the default `ABLETON_SHORTCUTS=preserve` keeps
all desktop shortcuts unchanged.

### GNOME restoration and recovery

The launcher saves the exact GNOME values before it changes them. It restores
those values after all Live sessions exit.

If Live stops unexpectedly, the recovery process restores the saved values
after all Live sessions stop. If that recovery process also stops, the next
launch finds the saved values and restores them.

A failed restore keeps its data. Recovery continues to try, and a later launch
can also complete the restore.

Changes made by the user take priority. If you edit a held shortcut while Live
runs, the launcher keeps your new value instead of replacing it with an older
saved value.

The launcher changes shortcuts only when GNOME, the required desktop tools,
and private temporary storage are available. It also confirms that Live exists
before it starts a new hold. Recovery remains available if Live is later
removed.

## Current limits

The automatic desktop change supports GNOME. It does not change KDE or another
desktop. Change a conflicting shortcut in that desktop when necessary.

This work does not change AltGr or the way that Wine reports AltGr to Live.
The detailed [shortcut research](ABLETON-WINE-SHORTCUT-AUDIT.md) records that
open layout check and the wider list of possible desktop conflicts.

## Test tools

The repository contains the two tools used to check these mitigations.

Run the GNOME hold and recovery test:

```bash
scripts/test-shortcut-hold.sh
```

This test uses temporary data. It does not change the current GNOME settings.

Build and run the Wine menu test:

```bash
winegcc -Wall -Wextra -Werror -o altnum-menu-repro tools/altnum-menu-repro.c
./altnum-menu-repro.exe swallow
./altnum-menu-repro.exe pass
```

The `swallow` mode represents input that Live handles. It checks both Alt-key
release orders, an Alt-click, a menu letter, and Alt by itself. The `pass` mode
checks input that an application sends to normal Windows menu handling. Each
mode returns an error if a handled Alt action opens the menu, if Alt with a
menu letter fails, or if Alt by itself fails.

The Wine test needs a working Wine display. The GNOME test does not.

## Verification

The Wine change applies to the Wine 11.13 source and builds successfully. Both
modes of the saved Wine test pass with the patched build. The test checks its
own result. The GNOME test checks exact shortcut matching, normal use,
recovery, a failed restore, and changes made by the user.

The code has not yet been tested inside Ableton Live.
