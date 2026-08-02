# Show in Explorer uses the host file manager

Status: file targets fixed in release 2026.07.22.1 by Wine patch 0043. Folder
targets failed on some portal setups (issue 41 follow-up, 2026-07-23). Patch
0063 (2026-08-01) routes folder `/select` targets through the FileManager1
service. Patch 0064 (2026-08-01) does the same for the folder-open forms
(`/e,`, `/root,`, bare path), which the library panel uses. Neither is in a
published release and runtime verification is pending. Wine Explorer remains
the fallback.

## Request path

Live calls `ShellExecuteW` or `ShellExecuteExW` with:

```text
explorer.exe /select,"<path>"
```

The executable imports those functions, does not import
`SHOpenFolderAndSelectItems`, and contains the wide string `,/select,"`.
Unpatched Wine resolves `explorer.exe` and opens its own file browser.

XDG Desktop Portal provides
`org.freedesktop.portal.OpenURI.OpenDirectory`. It accepts a file descriptor
for the target. Backends connected to `org.freedesktop.FileManager1` can open
the containing directory and select the item.

## Patch 0043

[Patch 0043](../patches/0043-shell32-reveal-explorer-select-targets-through-the-X.patch)
reuses the portal code introduced by patch 0031:

1. comdlg32 adds `portal_open_directory`, which calls `OpenDirectory`.
2. comdlg32 exports `__wine_portal_show_item(path)`. It checks policy,
   converts the DOS path to a Unix path, and calls the Unix portal library.
3. shell32 recognizes Explorer `/select,` commands with an existing target
   and resolves that export with `LoadLibrary` and `GetProcAddress`. Dynamic
   lookup avoids an import cycle because comdlg32 already imports shell32.

The portal call waits for the method reply but not the later `Response`
signal, so Live does not wait for the file manager to finish handling the
request.

## Verification

[`tools/showexp.c`](../tools/showexp.c) is the source of the probe used during
development. This repository does not ship its compiled binary or a build
target for it. Tests on 2026-07-21 covered both `ShellExecuteExW` and
`ShellExecuteW`. With GNOME and Nemo, file and directory targets opened in the
host file manager. `dbus-monitor` recorded `OpenDirectory`, and Wine Explorer
did not start.

## Folder targets and patch 0063 (2026-08-01)

Issue 41 follow-up, 2026-07-23: with patch 0043 the reveal works for files
but not for folders on the reporter's setup. The 2026-07-21 tests above did
not catch this because that backend resolved directory descriptors.
`OpenDirectory` is only defined for files: it opens the directory containing
a local file. What a backend does with a directory descriptor varies by
xdg-desktop-portal version and backend.

[Patch 0063](../patches/0063-comdlg32-reveal-explorer-select-folder-targets-throu.patch)
identifies directory targets in `__wine_portal_show_item` with
`GetFileAttributesW` and sends them to the desktop file manager's own
`org.freedesktop.FileManager1` service on the session bus. The `ShowItems`
method opens the parent folder with the target selected, which matches
`explorer /select,"<folder>"` on Windows and Live's reveal on macOS. D-Bus
activation starts the file manager when it is not running. Paths become
`file://` URIs with every byte outside the RFC 3986 unreserved set
percent-encoded, so non-ASCII names survive regardless of locale.

Fallback order for folders: `ShowItems`, then the `OpenDirectory` portal
call, then Wine Explorer. File targets keep the patch 0043 path unchanged.
The `FileDialogPortal` policy covers the new call; `never` disables it
together with the rest of the reveal.

A 0063-only runtime, exercised against Live on GNOME (2026-08-01), showed
that the library panel's Show in Explorer never reaches this code: Live
issues `explorer.exe /e,"<folder>"` for that menu item, the folder-open
form, and 0043/0063 intercept only `/select,`. Wine Explorer opened with
`/e,C:\users\...\User Library` on its command line. Patch 0064 covers that
form; see below. The `tools/showexp.c` probe covers the `/select` folder
case when given a folder path. `dbus-monitor` should record a `ShowItems`
call on `org.freedesktop.FileManager1` for a folder `/select` target.

## Folder-open commands (patch 0064, 2026-08-01)

[Patch 0064](../patches/0064-shell32-route-explorer-folder-open-commands-to-the-h.patch)
extends the shell32 hook to the folder-open forms `/e,<dir>`, `/root,<dir>`
(in either order and combination) and a bare `<dir>`. Targets that resolve
to an existing directory go to a new comdlg32 export,
`__wine_portal_open_folder`, which calls
`org.freedesktop.FileManager1.ShowFolders`: the folder itself opens, as
`explorer /e` does on Windows. When `ShowFolders` fails the target falls
back to the 0063 reveal ladder (`ShowItems`, then the `OpenDirectory`
portal), then Wine Explorer. Any other switch, a missing target, or a file
target keeps Wine Explorer's behavior, and the `FileDialogPortal` policy
gates the call as before. Runtime verification is pending; `dbus-monitor`
should record a `ShowFolders` call for a library-panel reveal.

## Policy and fallback

The reveal uses the same `FileDialogPortal` policy as file dialogs. A
`never` value disables it; see
[ABLETON-WINE-FILE-PORTAL.md](ABLETON-WINE-FILE-PORTAL.md).

Wine Explorer starts when the policy refuses the portal, the target is
missing, the caller is 32-bit, the portal library is unavailable, or the
portal call fails. Policy and missing-target fallbacks were tested.

New WoW64 cannot load the portal Unix library for a 32-bit caller, so those
calls always use Wine Explorer. Since patch 0064 a plain
`explorer.exe <folder>` command whose target is an existing directory is
diverted too; before it, only `/select,` commands were.

Selection depends on the desktop backend. A backend may open the containing
folder without selecting the item.
