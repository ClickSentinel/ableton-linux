/* treespy - full window tree (top-levels + children) with rects, and what sits
 * at a given point.
 *
 * For the M4L misplaced-popup hunt: tooltips consistently land right-aligned to
 * x~1792 with top=320 regardless of the pointer, and no *top-level* window
 * explains that point. This dumps children too, and resolves an arbitrary
 * coordinate to the window under it, so the thing they are anchored to can be
 * identified by name rather than inferred.
 *
 *   x86_64-w64-mingw32-gcc -O2 -o treespy.exe treespy.c -lgdi32 -luser32
 *   wine treespy.exe              # whole tree
 *   wine treespy.exe 1792 320     # also resolve that point + flag near matches
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static long qx = -1, qy = -1;

static void line(HWND h, int depth)
{
    RECT r;
    if (!GetWindowRect(h, &r)) return;
    char cls[96] = {0}, title[96] = {0};
    GetClassNameA(h, cls, sizeof(cls) - 1);
    GetWindowTextA(h, title, sizeof(title) - 1);
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    DWORD st = (DWORD)GetWindowLongPtrA(h, GWL_STYLE);

    /* Flag any window whose right/top edge coincides with the queried point -
     * that is the shape of "the popup was aligned to this window". */
    char note[80] = {0};
    if (qx >= 0) {
        long dr = r.right - qx, dt = r.top - qy, dl = r.left - qx, db = r.bottom - qy;
#define AB(v) ((v) < 0 ? -(v) : (v))
        if (AB(dr) <= 12 && AB(dt) <= 12) snprintf(note, sizeof(note), "  <== top-RIGHT ~ query");
        else if (AB(dl) <= 12 && AB(dt) <= 12) snprintf(note, sizeof(note), "  <== top-LEFT ~ query");
        else if (AB(dr) <= 12) snprintf(note, sizeof(note), "  <== right edge ~ query x");
        else if (AB(db) <= 12) snprintf(note, sizeof(note), "  <== bottom ~ query y");
        else if (AB(dt) <= 12) snprintf(note, sizeof(note), "  <== top ~ query y");
#undef AB
    }

    printf("%*s(%6ld,%6ld)-(%6ld,%6ld) %5ldx%-5ld %s pid=%-5lu %s%s%s%s\n",
           depth * 2, "", (long)r.left, (long)r.top, (long)r.right, (long)r.bottom,
           (long)(r.right - r.left), (long)(r.bottom - r.top),
           IsWindowVisible(h) ? "vis" : "hid", (unsigned long)pid, cls,
           title[0] ? " / " : "", title[0] ? title : "", note);
    (void)st;
}

static void walk(HWND parent, int depth)
{
    if (depth > 6) return;
    for (HWND c = GetWindow(parent, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT)) {
        line(c, depth);
        walk(c, depth + 1);
    }
}

static BOOL CALLBACK top(HWND h, LPARAM p)
{
    (void)p;
    RECT r;
    if (!GetWindowRect(h, &r)) return TRUE;
    if (!IsWindowVisible(h) && (r.right - r.left) <= 1) return TRUE;
    line(h, 0);
    walk(h, 1);
    return TRUE;
}

int main(int argc, char **argv)
{
    if (argc >= 3) { qx = atol(argv[1]); qy = atol(argv[2]); }

    if (qx >= 0) {
        POINT pt = { (LONG)qx, (LONG)qy };
        HWND hit = WindowFromPoint(pt);
        printf("WindowFromPoint(%ld,%ld):\n", qx, qy);
        while (hit) {
            printf("  ");
            line(hit, 0);
            hit = GetAncestor(hit, GA_PARENT);
            if (hit == GetDesktopWindow()) break;
        }
        printf("\n");
    }

    printf("full window tree (indent = child depth)\n");
    EnumWindows(top, 0);
    return 0;
}
