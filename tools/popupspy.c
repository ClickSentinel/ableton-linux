/* popupspy - log every top-level window as it appears, with the cursor position
 * at that moment.
 *
 * For diagnosing misplaced popups: a context menu should appear at the cursor,
 * so the delta between the cursor and the new window's top-left says immediately
 * whether the app asked for the wrong position or something else moved it. Under
 * Wine a popup that maps *managed* is placed by the window manager instead of by
 * the app, which reads as a menu opening in a random part of the screen.
 * Live's own Preferences dropdowns avoid this by mapping unmanaged
 * (SWP_NOACTIVATE); see patches/0039 and notes/ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md.
 *
 *   x86_64-w64-mingw32-gcc -O2 -o popupspy.exe popupspy.c -lgdi32
 *   wine popupspy.exe [seconds]         # default 60
 *
 * Then reproduce: right-click inside an M4L device UI a few times, and for a
 * known-good comparison open a Live Preferences dropdown too.
 *
 * Style bits worth watching in the output:
 *   POPUP/CHILD  - a menu should be POPUP, not CHILD
 *   CAPTION, THICKFRAME, SYSMENU - any of these makes Wine manage the window
 *   TOOLWINDOW, NOACTIVATE       - hints it is meant to stay unmanaged
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_SEEN 8192

static HWND seen[MAX_SEEN];
static int  seen_n;
static POINT cursor_at_scan;
static int  priming = 1;   /* first sweep lists the pre-existing windows */
static int  listed;        /* how many of those were visible and worth showing */

/* Getting this measurement right took three tries, so the failures are worth
 * recording:
 *
 *   1. Reporting the first rect we see caught popups pre-move - a menu looked
 *      stuck at (0,0) when it was about to be placed.
 *   2. Reporting the rect after a fixed settle delay caught popups *post*-
 *      teardown instead: Max parks and shrinks a dismissed popup (300px wide
 *      -> a 16px sliver at a fixed anchor), which read as a huge misplacement.
 *
 * So both rects are reported, and a move is only called a misplacement when the
 * size stayed the same - a move that also resizes is teardown. Distinguishing
 * those two is what separates a real bug from noise here. */
#define SETTLE_MS 250
#define MAX_PENDING 256

struct pending {
    HWND  hwnd, owner;
    RECT  first;
    POINT cursor;
    DWORD due, style, ex, pid, tid;
    char  cls[128], title[128];
};
static struct pending pend[MAX_PENDING];
static int pend_n;
static DWORD t0;

static int already_seen(HWND h)
{
    for (int i = 0; i < seen_n; i++) if (seen[i] == h) return 1;
    return 0;
}

static void describe_style(DWORD s, DWORD ex, char *out, size_t n)
{
    out[0] = '\0';
    struct { DWORD bit; int is_ex; const char *name; } t[] = {
        { WS_POPUP,        0, "POPUP" },      { WS_CHILD,      0, "CHILD" },
        { WS_CAPTION,      0, "CAPTION" },    { WS_THICKFRAME, 0, "THICKFRAME" },
        { WS_SYSMENU,      0, "SYSMENU" },    { WS_BORDER,     0, "BORDER" },
        { WS_EX_TOOLWINDOW, 1, "TOOLWINDOW" },
        { WS_EX_NOACTIVATE, 1, "NOACTIVATE" },
        { WS_EX_TOPMOST,    1, "TOPMOST" },
        { WS_EX_APPWINDOW,  1, "APPWINDOW" },
        { WS_EX_LAYERED,    1, "LAYERED" },
        { WS_EX_DLGMODALFRAME, 1, "DLGMODALFRAME" },
    };
    for (size_t i = 0; i < sizeof(t)/sizeof(t[0]); i++) {
        DWORD v = t[i].is_ex ? ex : s;
        /* WS_CAPTION is two bits; require both so BORDER alone does not match. */
        DWORD want = t[i].bit;
        if ((v & want) == want) {
            if (out[0]) strncat(out, "|", n - strlen(out) - 1);
            strncat(out, t[i].name, n - strlen(out) - 1);
        }
    }
    if (!out[0]) strncpy(out, "-", n);
}

static BOOL CALLBACK visit(HWND hwnd, LPARAM param)
{
    (void)param;
    if (already_seen(hwnd)) return TRUE;

    /* Only remember windows that are visible NOW. Marking hidden ones as seen
     * suppresses them permanently, so a window that exists at startup but is
     * shown later never gets reported - which is how the Max device window went
     * missing from the first three captures despite being a popup's owner. */
    if (!IsWindowVisible(hwnd)) return TRUE;
    if (seen_n < MAX_SEEN) seen[seen_n++] = hwnd;

    /* During priming, list the pre-existing windows instead of skipping them. A
     * misplaced popup is often anchored to some *other* window's corner, and if
     * that window already existed it is invisible in an events-only log - which
     * is exactly what happened on the first two captures here. */
    if (priming) {
        RECT pr;
        if (GetWindowRect(hwnd, &pr) &&
            (pr.right - pr.left) > 1 && (pr.bottom - pr.top) > 1) {
            char pcls[128] = {0}, ptitle[128] = {0};
            GetClassNameA(hwnd, pcls, sizeof(pcls) - 1);
            GetWindowTextA(hwnd, ptitle, sizeof(ptitle) - 1);
            DWORD ppid = 0;
            GetWindowThreadProcessId(hwnd, &ppid);
            printf("  existing (%5ld,%5ld)-(%5ld,%5ld) %4ldx%-4ld pid=%-5lu %s%s%s\n",
                   (long)pr.left, (long)pr.top, (long)pr.right, (long)pr.bottom,
                   (long)(pr.right - pr.left), (long)(pr.bottom - pr.top),
                   (unsigned long)ppid, pcls,
                   ptitle[0] ? " / " : "", ptitle[0] ? ptitle : "");
            listed++;
        }
        return TRUE;
    }

    RECT r;
    if (!GetWindowRect(hwnd, &r)) return TRUE;
    if ((r.right - r.left) <= 1 || (r.bottom - r.top) <= 1) return TRUE;

    if (pend_n >= MAX_PENDING) return TRUE;
    struct pending *p = &pend[pend_n++];
    memset(p, 0, sizeof(*p));
    p->hwnd = hwnd;
    p->first = r;
    p->cursor = cursor_at_scan;
    p->due = GetTickCount() + SETTLE_MS;
    GetClassNameA(hwnd, p->cls, sizeof(p->cls) - 1);
    GetWindowTextA(hwnd, p->title, sizeof(p->title) - 1);
    p->style = (DWORD)GetWindowLongPtrA(hwnd, GWL_STYLE);
    p->ex    = (DWORD)GetWindowLongPtrA(hwnd, GWL_EXSTYLE);
    p->tid   = GetWindowThreadProcessId(hwnd, &p->pid);
    p->owner = GetWindow(hwnd, GW_OWNER);
    return TRUE;
}

/* Does any edge of `w` line up with any edge of the misplaced popup `t`? */
static const char *edge_match(const RECT *w, const RECT *t)
{
    const long TOL = 10;
#define CLOSE(a,b) (((a)-(b) <= TOL) && ((b)-(a) <= TOL))
    if (CLOSE(w->right, t->right) && CLOSE(w->top, t->top))    return "  <== top-RIGHT corner matches";
    if (CLOSE(w->left,  t->left)  && CLOSE(w->top, t->top))    return "  <== top-LEFT corner matches";
    if (CLOSE(w->right, t->right))                            return "  <== right edge matches";
    if (CLOSE(w->left,  t->right))                            return "  <== its left edge = popup right";
    if (CLOSE(w->top,   t->top))                              return "  <== top edge matches";
    if (CLOSE(w->bottom, t->top))                             return "  <== its bottom = popup top";
#undef CLOSE
    return "";
}

static RECT anchor_target;
static HWND anchor_self;          /* the popup being reported - never match it */
static int  anchor_depth;

static void anchor_walk(HWND parent)
{
    HWND c = GetWindow(parent, GW_CHILD);
    for (; c; c = GetWindow(c, GW_HWNDNEXT)) {
        RECT r;
        if (!IsWindowVisible(c) || !GetWindowRect(c, &r)) continue;
        if ((r.right - r.left) <= 4 || (r.bottom - r.top) <= 4) continue;
        const char *m = edge_match(&r, &anchor_target);
        /* Children are numerous; only surface the ones that actually line up. */
        if (*m) {
            char cls[96] = {0}, title[96] = {0};
            GetClassNameA(c, cls, sizeof(cls) - 1);
            GetWindowTextA(c, title, sizeof(title) - 1);
            printf("      child (%5ld,%5ld)-(%5ld,%5ld) %s%s%s%s\n",
                   (long)r.left, (long)r.top, (long)r.right, (long)r.bottom, cls,
                   title[0] ? " / " : "", title[0] ? title : "", m);
        }
        if (anchor_depth < 4) { anchor_depth++; anchor_walk(c); anchor_depth--; }
    }
}

static BOOL CALLBACK anchor_visit(HWND hwnd, LPARAM param)
{
    (void)param;
    RECT r;
    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, &r)) return TRUE;
    if ((r.right - r.left) <= 1 || (r.bottom - r.top) <= 1) return TRUE;
    char cls[96] = {0}, title[96] = {0};
    GetClassNameA(hwnd, cls, sizeof(cls) - 1);
    GetWindowTextA(hwnd, title, sizeof(title) - 1);
    /* Skip self-comparison: the popup is in this enumeration too, and matching
     * its own rect is what made the first version of this report useless. */
    const char *m = (hwnd == anchor_self) ? "  (this is the popup itself)"
                                          : edge_match(&r, &anchor_target);
    printf("      (%5ld,%5ld)-(%5ld,%5ld) %s%s%s%s\n",
           (long)r.left, (long)r.top, (long)r.right, (long)r.bottom, cls,
           title[0] ? " / " : "", title[0] ? title : "", m);
    if (hwnd != anchor_self) anchor_walk(hwnd);
    return TRUE;
}

static void dump_anchor_candidates(const RECT *where, HWND self)
{
    anchor_target = *where;
    anchor_self = self;
    anchor_depth = 0;
    printf("    anchor hunt for (%ld,%ld)-(%ld,%ld) "
           "(top-levels, plus only matching children):\n",
           (long)where->left, (long)where->top,
           (long)where->right, (long)where->bottom);
    EnumWindows(anchor_visit, 0);
}

static void flush_settled(void)
{
    DWORD now = GetTickCount();
    for (int i = 0; i < pend_n; i++) {
        struct pending *p = &pend[i];
        if ((long)(now - p->due) < 0) continue;

        RECT s = { 0 };
        BOOL alive = IsWindow(p->hwnd) && GetWindowRect(p->hwnd, &s);
        BOOL moved = alive && (s.left != p->first.left || s.top != p->first.top);
        const RECT *j = alive ? &s : &p->first;      /* judge the settled rect */

        long dx = j->left - p->cursor.x, dy = j->top - p->cursor.y;
        long adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
        /* A context menu is placed at the cursor. Tens of pixels is normal when
         * it flips near a screen edge; hundreds means something else placed it. */
        const char *verdict = (adx <= 80 && ady <= 120) ? "at-cursor"
                            : (adx <= 300 && ady <= 300) ? "NEAR-ish"
                            : "FAR-FROM-CURSOR";

        char sty[256];
        describe_style(p->style, p->ex, sty, sizeof(sty));

        printf("+ [%5.1fs] hwnd=%p cls=\"%s\"%s%s%s\n",
               (GetTickCount() - t0) / 1000.0, (void *)p->hwnd, p->cls,
               p->title[0] ? " title=\"" : "", p->title[0] ? p->title : "",
               p->title[0] ? "\"" : "");
        printf("    first  =(%ld,%ld) %ldx%ld\n",
               (long)p->first.left, (long)p->first.top,
               (long)(p->first.right - p->first.left),
               (long)(p->first.bottom - p->first.top));
        /* Distinguish a genuine reposition from Max recycling the window: on
         * dismissal it parks a popup at a fixed anchor AND collapses it to a
         * sliver. A same-size move is a real misplacement; a move that also
         * changes size is teardown and must not be read as one. Conflating
         * these produced a wrong "all menus were placed correctly" verdict. */
        long fw = p->first.right - p->first.left, fh = p->first.bottom - p->first.top;
        long sw = s.right - s.left, sh = s.bottom - s.top;
        BOOL resized = alive && (sw != fw || sh != fh);
        if (!alive)
            printf("    settled= <window hidden/destroyed before settle>\n");
        else
            printf("    settled=(%ld,%ld) %ldx%ld%s\n", (long)s.left, (long)s.top,
                   sw, sh,
                   !moved ? ""
                   : resized ? "   (moved AND resized -> teardown, ignore)"
                             : "   (MOVED, SAME SIZE -> REAL MISPLACEMENT)");
        printf("    cursor =(%ld,%ld) delta=(%+ld,%+ld) %s\n",
               (long)p->cursor.x, (long)p->cursor.y, dx, dy, verdict);

        /* An owner rect that the popup hugs means it was placed relative to that
         * window rather than the pointer. */
        if (p->owner && IsWindow(p->owner)) {
            RECT o = { 0 };
            GetWindowRect(p->owner, &o);
            char ocls[96] = { 0 };
            GetClassNameA(p->owner, ocls, sizeof(ocls) - 1);
            printf("    owner  =%p \"%s\" rect=(%ld,%ld)-(%ld,%ld)\n",
                   (void *)p->owner, ocls, (long)o.left, (long)o.top,
                   (long)o.right, (long)o.bottom);
        }
        printf("    style=%08lx ex=%08lx [%s] pid=%lu tid=%lu\n",
               (unsigned long)p->style, (unsigned long)p->ex, sty,
               (unsigned long)p->pid, (unsigned long)p->tid);

        /* Every misplaced popup here lands on one fixed point, so find whatever
         * window owns that point: list the visible top-levels and mark any whose
         * edge or corner coincides with where the popup ended up. */
        if (alive && verdict[0] == 'F')
            dump_anchor_candidates(j, p->hwnd);
        fflush(stdout);

        pend[i--] = pend[--pend_n];   /* compact; re-test the swapped-in entry */
    }
}

int main(int argc, char **argv)
{
    int secs = 60;
    if (argc > 1) secs = atoi(argv[1]);
    if (secs <= 0) secs = 60;

    /* List the pre-existing windows, then watch for new ones. The listing is not
     * noise: it is how you find the window a misplaced popup is anchored to. */
    t0 = GetTickCount();
    GetCursorPos(&cursor_at_scan);
    printf("popupspy: pre-existing visible windows (anchor candidates)\n");
    EnumWindows(visit, 0);
    printf("popupspy: %d visible window(s) listed above (of %d total); new popups follow\n", listed, seen_n);
    if (!listed) printf("  !! none visible - is Live actually running?\n");
    priming = 0;

    printf("popupspy: watching for %d seconds. Right-click inside an M4L device UI.\n", secs);
    printf("          For a known-good comparison, open a Live Preferences dropdown.\n\n");
    fflush(stdout);

    DWORD end = GetTickCount() + (DWORD)secs * 1000;
    while (GetTickCount() < end) {
        GetCursorPos(&cursor_at_scan);
        EnumWindows(visit, 0);
        flush_settled();
        Sleep(25);
    }
    Sleep(SETTLE_MS);
    flush_settled();
    printf("\npopupspy: done (%d windows tracked)\n", seen_n);
    return 0;
}
