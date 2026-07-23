/* setsyscolors.c — apply win32 system colors from the command line, for the
 * launcher's unified-top-bar watcher (issue #32). SetSysColors updates the
 * live in-memory color table and broadcasts WM_SYSCOLORCHANGE to every
 * top-level window, so a RUNNING Live picks up the values on its next repaint.
 * (Its registry persistence claim doesn't hold — a plain registry write only
 * reaches processes started afterwards, which is why this must run in-prefix.)
 *
 * Used to also EnumWindows + DrawMenuBar on every window here, because Wine's
 * own SetSysColors forced a repaint of client areas only (RDW_ALLCHILDREN)
 * and never the non-client area where a native menu bar actually lives. Fixed
 * upstream instead (patches/0049-win32u-include-the-non-client-area-in-setsyscolors.patch:
 * one flag, RDW_FRAME, added to the RedrawWindow call already inside
 * NtUserSetSysColors) rather than compensating for a real Wine gap from out
 * here — same repaint, for any caller, with nothing extra needed on this side.
 *
 * Known remaining issue, unrelated to the above and NOT fixed by it: the
 * repaint this produces can still take anywhere from well under a second to
 * several seconds to actually become visible, and in the live in-app-theme-
 * switch path reliably seems to need some unrelated interaction (hovering the
 * bar, clicking something) to show up at all. Tried RedrawWindow(...
 * RDW_UPDATENOW...) and a synthetic SendInput mouse nudge from this file;
 * neither made a real difference in the real path and both were reverted
 * rather than keep dead code. See FINDINGS-TEXT-RENDERING-BLUR-2026-07-21.md.
 *
 * usage:  setsyscolors.exe Name=R,G,B [Name=R,G,B ...]
 * Names mirror the [Control Panel\Colors] value names the launcher syncs.
 * build:  tools/build_setsyscolors.sh (real PE via clang, wine headers, no CRT) */
#include <windows.h>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

static const struct { const char *name; int index; } color_map[] = {
    { "MenuBar",             COLOR_MENUBAR },
    { "Menu",                COLOR_MENU },
    { "MenuText",            COLOR_MENUTEXT },
    { "MenuHilight",         COLOR_MENUHILIGHT },
    { "Hilight",             COLOR_HIGHLIGHT },
    { "HilightText",         COLOR_HIGHLIGHTTEXT },
    { "ActiveTitle",         COLOR_ACTIVECAPTION },
    { "GradientActiveTitle", COLOR_GRADIENTACTIVECAPTION },
    { "TitleText",           COLOR_CAPTIONTEXT },
    { "ButtonFace",          COLOR_BTNFACE },
    { "ButtonText",          COLOR_BTNTEXT },
    { "GrayText",            COLOR_GRAYTEXT },
};

/* no CRT: the few string helpers needed, spelled out */
static int name_matches( const char *name, const char *tok, int len )
{
    int i;
    for (i = 0; i < len; i++)
        if (!name[i] || name[i] != tok[i]) return 0;
    return !name[i];
}

static int parse_byte( const char **p, int *out )   /* 0-255, advances *p */
{
    int v = 0, digits = 0;
    while (**p >= '0' && **p <= '9')
    {
        v = v * 10 + (**p - '0');
        if (v > 255) return 0;
        (*p)++; digits++;
    }
    if (!digits) return 0;
    *out = v;
    return 1;
}

int mainCRTStartup( void )
{
    INT idx[ARRAY_SIZE(color_map)];
    COLORREF val[ARRAY_SIZE(color_map)];
    int n = 0;
    const char *p = GetCommandLineA();

    /* skip the (possibly quoted) program token */
    if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
    else while (*p && *p != ' ') p++;

    while (*p)
    {
        const char *tok;
        int len, i, r, g, b;

        while (*p == ' ') p++;
        if (!*p) break;
        tok = p;
        while (*p && *p != '=' && *p != ' ') p++;
        if (*p != '=') return 1;
        len = (int)(p - tok);
        p++;
        if (!parse_byte( &p, &r ) || *p++ != ',' ||
            !parse_byte( &p, &g ) || *p++ != ',' ||
            !parse_byte( &p, &b )) return 1;
        if (*p && *p != ' ') return 1;

        for (i = 0; i < ARRAY_SIZE(color_map); i++)
            if (name_matches( color_map[i].name, tok, len )) break;
        if (i == ARRAY_SIZE(color_map)) return 1;   /* unknown name: refuse the lot */
        if (n < ARRAY_SIZE(color_map))
        {
            idx[n] = color_map[i].index;
            val[n] = RGB( r, g, b );
            n++;
        }
    }

    if (!n) return 1;
    if (!SetSysColors( n, idx, val )) return 2;
    return 0;
}
