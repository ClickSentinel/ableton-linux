/* monprobe - what does Wine tell an app about the screen and its usable area?
 *
 * JUCE (and most toolkits) place a tooltip or menu near the mouse and then clamp
 * it into the monitor's work area. If Wine reports a work area that does not
 * match the real screen, everything gets shoved into that rect - which shows up
 * as popups landing on one constant point far from the cursor, regardless of
 * where you clicked. That is the symptom being chased in the M4L popup
 * misplacement, where popups consistently settle right-aligned to x~1792 with
 * top=320 no matter the pointer position.
 *
 *   x86_64-w64-mingw32-gcc -O2 -o monprobe.exe monprobe.c -lgdi32 -luser32
 *   wine monprobe.exe
 *
 * Compare the numbers below against the actual desktop geometry. A work area
 * whose edges coincide with where popups land is the culprit.
 */

#include <windows.h>
#include <stdio.h>

static int mon_index;

static BOOL CALLBACK mon_cb(HMONITOR h, HDC dc, LPRECT rc, LPARAM param)
{
    (void)dc; (void)rc; (void)param;
    MONITORINFOEXA mi;
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoA(h, (MONITORINFO *)&mi)) return TRUE;
    const RECT *m = &mi.rcMonitor, *w = &mi.rcWork;
    printf("  monitor %d  \"%s\"%s\n", mon_index++, mi.szDevice,
           (mi.dwFlags & MONITORINFOF_PRIMARY) ? "  (primary)" : "");
    printf("      full  =(%5ld,%5ld)-(%5ld,%5ld)  %ldx%ld\n",
           (long)m->left, (long)m->top, (long)m->right, (long)m->bottom,
           (long)(m->right - m->left), (long)(m->bottom - m->top));
    printf("      work  =(%5ld,%5ld)-(%5ld,%5ld)  %ldx%ld%s\n",
           (long)w->left, (long)w->top, (long)w->right, (long)w->bottom,
           (long)(w->right - w->left), (long)(w->bottom - w->top),
           (w->left != m->left || w->top != m->top ||
            w->right != m->right || w->bottom != m->bottom)
               ? "   <== work area differs from full monitor" : "");
    return TRUE;
}

int main(void)
{
    RECT wa = { 0 };
    POINT cur = { 0 };

    printf("GetSystemMetrics\n");
    printf("  SM_CXSCREEN / SM_CYSCREEN           = %d x %d\n",
           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    printf("  SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN = %d , %d\n",
           GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
    printf("  SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN = %d x %d\n",
           GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
    printf("  SM_CMONITORS                        = %d\n",
           GetSystemMetrics(SM_CMONITORS));

    if (SystemParametersInfoA(SPI_GETWORKAREA, 0, &wa, 0))
        printf("\nSPI_GETWORKAREA (primary) = (%ld,%ld)-(%ld,%ld)  %ldx%ld\n",
               (long)wa.left, (long)wa.top, (long)wa.right, (long)wa.bottom,
               (long)(wa.right - wa.left), (long)(wa.bottom - wa.top));
    else
        printf("\nSPI_GETWORKAREA failed\n");

    printf("\nEnumDisplayMonitors\n");
    EnumDisplayMonitors(NULL, NULL, mon_cb, 0);

    GetCursorPos(&cur);
    printf("\nGetCursorPos = (%ld,%ld)\n", (long)cur.x, (long)cur.y);

    /* Which monitor does Wine think the pointer is on, and what does it consider
     * usable there? A toolkit clamping a popup uses exactly this pair. */
    HMONITOR hm = MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST);
    MONITORINFOEXA mi;
    mi.cbSize = sizeof(mi);
    if (hm && GetMonitorInfoA(hm, (MONITORINFO *)&mi))
        printf("MonitorFromPoint(cursor) work = (%ld,%ld)-(%ld,%ld)\n",
               (long)mi.rcWork.left, (long)mi.rcWork.top,
               (long)mi.rcWork.right, (long)mi.rcWork.bottom);

    printf("\nDPI\n");
    HDC dc = GetDC(NULL);
    if (dc) {
        printf("  LOGPIXELSX / LOGPIXELSY = %d / %d\n",
               GetDeviceCaps(dc, LOGPIXELSX), GetDeviceCaps(dc, LOGPIXELSY));
        printf("  HORZRES / VERTRES       = %d x %d\n",
               GetDeviceCaps(dc, HORZRES), GetDeviceCaps(dc, VERTRES));
        ReleaseDC(NULL, dc);
    }
    return 0;
}
