# Show in Explorer uses the host file manager

Status: fixed in release 2026.07.22.1 by Wine patch 0043. When the XDG portal
accepts Live's request, Show in Explorer opens the host file manager. Wine
Explorer remains the fallback.

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

## Policy and fallback

The reveal uses the same `FileDialogPortal` policy as file dialogs. A
`never` value disables it; see
[ABLETON-WINE-FILE-PORTAL.md](ABLETON-WINE-FILE-PORTAL.md).

Wine Explorer starts when the policy refuses the portal, the target is
missing, the caller is 32-bit, the portal library is unavailable, or the
portal call fails. Policy and missing-target fallbacks were tested.

New WoW64 cannot load the portal Unix library for a 32-bit caller, so those
calls always use Wine Explorer. A plain `explorer.exe <folder>` command also
keeps the Wine behavior because patch 0043 handles only `/select,`.

Selection depends on the desktop backend. A backend may open the containing
folder without selecting the item.
