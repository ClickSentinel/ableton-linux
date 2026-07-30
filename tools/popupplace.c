/* popupplace - which window styles make Wine hand popup placement to the WM?
 *
 * A menu must appear exactly where the app puts it. Under Wine a top-level that
 * is_window_managed() calls "managed" is placed by the window manager instead,
 * so its position becomes advisory and racy - the menu lands somewhere else.
 *
 * JUCE menus (Max for Live devices) are WS_POPUP|WS_SYSMENU with
 * WS_EX_TOOLWINDOW and no WS_CAPTION. winex11.drv's is_window_managed has:
 *
 *     if (style & WS_POPUP) {
 *         if (style & WS_SYSMENU) return TRUE;   // "popup with sysmenu == caption"
 *
 * so they are managed, while win32u's own #32768 menus (WS_POPUP, no SYSMENU)
 * are not - which is why Live's menus are fine and M4L's jump around.
 *
 * This creates popups with each style combination at a known position and
 * reports requested vs actual rect, repeated so an intermittent race shows up.
 *
 *   x86_64-w64-mingw32-gcc -O2 -o popupplace.exe popupplace.c -lgdi32
 *   wine popupplace.exe [reps]        # default 6
 *
 * A row that never drifts is unmanaged. A row that drifts, even sometimes, is
 * being placed by the window manager.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define REQ_X 400
#define REQ_Y 300
#define REQ_W 200
#define REQ_H 72

struct variant {
    const char *name;
    DWORD style;
    DWORD ex_style;
    BOOL  noactivate;      /* show with SWP_NOACTIVATE */
    int   seq;             /* 0 = create at target then SetWindowPos
                            * 1 = create at 0,0 then move+show in one call
                            * 2 = create at 0,0, SHOW first, then move (post-map
                            *     move goes to the WM asynchronously when managed) */
};

#define JUCE_EX (WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_LAYERED)

static const struct variant variants[] = {
    /* baseline: what win32u's own #32768 menus look like */
    { "POPUP (like #32768)",           WS_POPUP,            WS_EX_TOPMOST, TRUE,  0 },
    /* the single bit under suspicion - drifts, but TOOLWINDOW below rescues it */
    { "POPUP|SYSMENU",                 WS_POPUP|WS_SYSMENU, WS_EX_TOPMOST, TRUE,  0 },
    /* the exact JUCE / Max for Live menu shape, three creation sequences */
    { "JUCE shape, pos at create",     WS_POPUP|WS_SYSMENU, JUCE_EX,       TRUE,  0 },
    { "JUCE shape, move+show at once", WS_POPUP|WS_SYSMENU, JUCE_EX,       TRUE,  1 },
    { "JUCE shape, SHOW then move",    WS_POPUP|WS_SYSMENU, JUCE_EX,       TRUE,  2 },
    /* activated variants: isolates the "activated windows are managed" rule */
    { "JUCE shape activated, at create", WS_POPUP|WS_SYSMENU, JUCE_EX,     FALSE, 0 },
    { "JUCE shape activated, SHOW then move", WS_POPUP|WS_SYSMENU, JUCE_EX, FALSE, 2 },
};

int main(int argc, char **argv)
{
    int reps = argc > 1 ? atoi(argv[1]) : 6;
    if (reps <= 0) reps = 6;

    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "popupplace";
    if (!RegisterClassA(&wc)) { printf("RegisterClass failed\n"); return 2; }

    printf("requested %dx%d at (%d,%d), %d reps each\n\n",
           REQ_W, REQ_H, REQ_X, REQ_Y, reps);
    printf("%-34s %-8s %s\n", "VARIANT", "DRIFTED", "observed positions");
    printf("%.78s\n", "-----------------------------------------------------------------------------------");

    int any_drift = 0;
    for (size_t v = 0; v < sizeof(variants)/sizeof(variants[0]); v++) {
        const struct variant *V = &variants[v];
        int drifted = 0;
        char obs[512] = { 0 };

        for (int i = 0; i < reps; i++) {
            int cx = V->seq == 0 ? REQ_X : 0, cy = V->seq == 0 ? REQ_Y : 0;
            HWND w = CreateWindowExA(V->ex_style, "popupplace", "menu", V->style,
                                     cx, cy, REQ_W, REQ_H,
                                     NULL, NULL, wc.hInstance, NULL);
            if (!w) { printf("  CreateWindowEx failed for %s\n", V->name); break; }

            UINT flags = SWP_SHOWWINDOW | SWP_NOZORDER;
            if (V->noactivate) flags |= SWP_NOACTIVATE;

            if (V->seq == 2) {
                /* Map first, then move. When the window is managed this move is
                 * a request to the WM rather than a direct placement, which is
                 * where an intermittent misplacement would come from. */
                ShowWindow(w, V->noactivate ? SW_SHOWNOACTIVATE : SW_SHOW);
                MSG m;
                while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
                    TranslateMessage(&m); DispatchMessageA(&m);
                }
                SetWindowPos(w, NULL, REQ_X, REQ_Y, REQ_W, REQ_H,
                             SWP_NOZORDER | (V->noactivate ? SWP_NOACTIVATE : 0));
            } else {
                SetWindowPos(w, NULL, REQ_X, REQ_Y, REQ_W, REQ_H, flags);
            }

            /* Let the WM act: a managed window is mapped, then possibly moved. */
            for (int spin = 0; spin < 25; spin++) {
                MSG m;
                while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
                    TranslateMessage(&m); DispatchMessageA(&m);
                }
                Sleep(20);
            }

            RECT r = { 0 };
            GetWindowRect(w, &r);
            if (r.left != REQ_X || r.top != REQ_Y) {
                drifted++;
                char one[64];
                snprintf(one, sizeof(one), "(%ld,%ld) ", (long)r.left, (long)r.top);
                strncat(obs, one, sizeof(obs) - strlen(obs) - 1);
            }
            DestroyWindow(w);
        }

        if (drifted) any_drift = 1;
        printf("%-34s %d/%-6d %s\n", V->name, drifted, reps,
               drifted ? obs : "all exactly at requested position");
    }

    printf("\n%s\n", any_drift
        ? "At least one variant is being placed by the window manager."
        : "No drift observed; try more reps, or the WM honoured every hint this run.");
    return 0;
}
