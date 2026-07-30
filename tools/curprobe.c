/* curprobe - does Wine's GetCursorPos agree with the real X11 pointer?
 *
 * JUCE positions a tooltip by calling GetCursorPos and moving the window there.
 * In the M4L misplaced-tooltip trace the app places the tooltip correctly at the
 * pointer, then calls GetCursorPos and immediately moves it far away - so if
 * Wine returns a wrong cursor position, that is the whole bug, and it is ours.
 *
 * Relay tracing cannot show GetCursorPos's POINT out-parameter, hence this.
 * Prints one line per sample; compare against xdotool sampled at the same time
 * (tools/curprobe.sh does the pairing).
 *
 *   x86_64-w64-mingw32-gcc -O2 -o curprobe.exe curprobe.c -luser32
 *   wine curprobe.exe [seconds] [interval_ms]
 *
 * Output: "<unix_ms> <x> <y> <foreground_hwnd>"
 * The foreground window is included because the reported symptom is that focus
 * changes when a tooltip appears - if the cursor goes wrong at the same moment
 * the foreground window changes, that pins the mechanism.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 30;
    int ival = argc > 2 ? atoi(argv[2]) : 50;
    if (secs <= 0) secs = 30;
    if (ival <= 0) ival = 50;

    /* Wine's epoch-based time so the samples can be paired with xdotool's. */
    FILETIME ft;
    ULARGE_INTEGER u;
    DWORD end = GetTickCount() + (DWORD)secs * 1000;

    setvbuf(stdout, NULL, _IOLBF, 0);
    while (GetTickCount() < end) {
        POINT p = { -1, -1 };
        BOOL ok = GetCursorPos(&p);
        HWND fg = GetForegroundWindow();
        GetSystemTimeAsFileTime(&ft);
        u.LowPart = ft.dwLowDateTime;
        u.HighPart = ft.dwHighDateTime;
        /* FILETIME is 100ns since 1601; convert to unix milliseconds. */
        unsigned long long ms = (u.QuadPart - 116444736000000000ULL) / 10000ULL;
        printf("%llu %ld %ld %p%s\n", ms, (long)p.x, (long)p.y, (void *)fg,
               ok ? "" : " GETCURSORPOS_FAILED");
        Sleep(ival);
    }
    return 0;
}
