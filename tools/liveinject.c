/* liveinject.c — drive Ableton Live inside its Wine prefix via SendInput.
 * Runs as a separate Wine process in the same prefix/wineserver session, so
 * input goes through Wine's internal foreground queue — no X/XTEST needed.
 * NOTE: this path BYPASSES XWayland/winex11 event delivery; use it to drive
 * Live, not to prove that real (compositor-path) input works.
 *
 * CRT-free PE build (wsprintfA/WriteFile, mainCRTStartup) — see
 * build_swamprobe.sh in this dir, which builds this too.
 *
 * usage: liveinject <cmd> [args]
 *   info                 print Live main window hwnd + rect (physical coords)
 *   fg                   SetForegroundWindow(main Live window)
 *   fgw <hexhwnd>        SetForegroundWindow(that window)
 *   newmidi              fg + Ctrl+Shift+T (insert MIDI track)
 *   ctrlf                Ctrl+F (focus browser search)
 *   ctrlaltp             Ctrl+Alt+P (toggle plug-in windows)
 *   ctrlalt7             Ctrl+Alt+7 (toggle Learn View)
 *   ctrlq                Ctrl+Q (quit)
 *   type <text>          type ascii text (unicode events)
 *   key <enter|down|up|left|right|esc|tab|f1>
 *   click <x> <y>        move + left click at physical virtual-screen coords
 *   dblclick <x> <y>     move + double click
 *   move <x> <y>         just move the cursor
 *   close                PostMessage(WM_CLOSE) to Live main window
 */

#include <windows.h>

static HANDLE g_out;
static char   obuf[512];
static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( obuf, __VA_ARGS__ ); emit( obuf ); } while (0)

static void send_vk( WORD vk, BOOL up )
{
    INPUT in;
    memset( &in, 0, sizeof(in) );
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    SendInput( 1, &in, sizeof(in) );
    Sleep( 40 );
}
static void tap( WORD vk ) { send_vk( vk, FALSE ); send_vk( vk, TRUE ); }

/* Scancode variant: Live's shortcut handling ignores plain-VK synthetic
 * input for some chords (Ctrl+Alt+7); hardware scancodes get through. */
static void send_sc( WORD vk, BOOL up )
{
    INPUT in;
    memset( &in, 0, sizeof(in) );
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = MapVirtualKeyA( vk, MAPVK_VK_TO_VSC );
    in.ki.dwFlags = KEYEVENTF_SCANCODE | (up ? KEYEVENTF_KEYUP : 0);
    SendInput( 1, &in, sizeof(in) );
    Sleep( 40 );
}

static void tap_sc( WORD vk ) { send_sc( vk, FALSE ); send_sc( vk, TRUE ); }

static void type_text( const char *s )
{
    for (; *s; s++)
    {
        INPUT in;
        memset( &in, 0, sizeof(in) );
        in.type = INPUT_KEYBOARD;
        in.ki.dwFlags = KEYEVENTF_UNICODE;
        in.ki.wScan = (WCHAR)*s;
        SendInput( 1, &in, sizeof(in) );
        in.ki.dwFlags |= KEYEVENTF_KEYUP;
        SendInput( 1, &in, sizeof(in) );
        Sleep( 50 );
    }
}

static void move_to( int x, int y )
{
    INPUT in;
    memset( &in, 0, sizeof(in) );
    in.type = INPUT_MOUSE;
    in.mi.dx = (LONG)((x * 65535) / GetSystemMetrics( SM_CXVIRTUALSCREEN ));
    in.mi.dy = (LONG)((y * 65535) / GetSystemMetrics( SM_CYVIRTUALSCREEN ));
    in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput( 1, &in, sizeof(in) );
    Sleep( 80 );
}

static void btn( DWORD flag )
{
    INPUT in;
    memset( &in, 0, sizeof(in) );
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = flag;
    SendInput( 1, &in, sizeof(in) );
    Sleep( 80 );
}

static int my_atoi( const char *s )
{
    int v = 0, neg = 0;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

static UINT_PTR my_hextoptr( const char *s )
{
    UINT_PTR v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    for (; *s; s++) {
        char c = *s;
        if (c >= '0' && c <= '9') v = v * 16 + (c - '0');
        else if (c >= 'a' && c <= 'f') v = v * 16 + (c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v = v * 16 + (c - 'A' + 10);
        else break;
    }
    return v;
}

void mainCRTStartup( void )
{
    typedef BOOL (WINAPI *pSetPCtx)(DPI_AWARENESS_CONTEXT);
    pSetPCtx p_setctx = (pSetPCtx) GetProcAddress( GetModuleHandleA( "user32.dll" ),
                                                   "SetProcessDpiAwarenessContext" );
    HWND live;
    char a1[64] = {0}, a2[256] = {0}, a3[64] = {0};
    int ret = 0;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    if (p_setctx) p_setctx( DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 );

    {   /* args: a2 may contain spaces for `type` (rest-of-line) */
        const char *s = GetCommandLineA();
        int j;
        if (*s == '"') { s++; while (*s && *s != '"') s++; if (*s) s++; }
        else while (*s && *s != ' ') s++;
        while (*s == ' ') s++;
        j = 0; while (*s && *s != ' ' && j < 63) a1[j++] = *s++;
        a1[j] = 0;
        while (*s == ' ') s++;
        if (!lstrcmpA( a1, "type" )) {
            j = 0; while (*s && j < 255) a2[j++] = *s++;
            a2[j] = 0;
        } else {
            j = 0; while (*s && *s != ' ' && j < 255) a2[j++] = *s++;
            a2[j] = 0;
            while (*s == ' ') s++;
            j = 0; while (*s && *s != ' ' && j < 63) a3[j++] = *s++;
            a3[j] = 0;
        }
    }

    live = FindWindowW( L"Ableton Live Window Class", NULL );

    if (!a1[0] || !lstrcmpA( a1, "info" ))
    {
        RECT r; r.left = r.top = r.right = r.bottom = 0;
        if (live) GetWindowRect( live, &r );
        P( "live hwnd=%p rect=(%ld,%ld)-(%ld,%ld) vscreen=%dx%d\n", live,
           r.left, r.top, r.right, r.bottom,
           GetSystemMetrics( SM_CXVIRTUALSCREEN ), GetSystemMetrics( SM_CYVIRTUALSCREEN ) );
        ret = live ? 0 : 1;
    }
    else if (!lstrcmpA( a1, "fg" ) || !lstrcmpA( a1, "newmidi" ))
    {
        if (!live) ret = 1;
        else
        {
            SetForegroundWindow( live );
            Sleep( 400 );
            if (!lstrcmpA( a1, "newmidi" ))
            {
                send_vk( VK_CONTROL, FALSE );
                send_vk( VK_SHIFT, FALSE );
                tap( 'T' );
                send_vk( VK_SHIFT, TRUE );
                send_vk( VK_CONTROL, TRUE );
            }
        }
    }
    else if (!lstrcmpA( a1, "fgw" ))
    {
        HWND w = (HWND)my_hextoptr( a2 );
        if (w) { SetForegroundWindow( w ); Sleep( 300 ); }
        else ret = 1;
    }
    else if (!lstrcmpA( a1, "ctrlf" ))
    {
        send_vk( VK_CONTROL, FALSE );
        tap( 'F' );
        send_vk( VK_CONTROL, TRUE );
    }
    else if (!lstrcmpA( a1, "ctrlaltp" ))
    {
        send_vk( VK_CONTROL, FALSE );
        send_vk( VK_MENU, FALSE );
        tap( 'P' );
        send_vk( VK_MENU, TRUE );
        send_vk( VK_CONTROL, TRUE );
    }
    else if (!lstrcmpA( a1, "ctrlalt7" ))
    {
        send_sc( VK_CONTROL, FALSE );
        send_sc( VK_MENU, FALSE );
        tap_sc( '7' );
        send_sc( VK_MENU, TRUE );
        send_sc( VK_CONTROL, TRUE );
    }
    else if (!lstrcmpA( a1, "clearmods" ))
    {   /* release possibly-stuck modifiers */
        send_vk( VK_SHIFT, TRUE );
        send_vk( VK_LSHIFT, TRUE );
        send_vk( VK_RSHIFT, TRUE );
        send_vk( VK_CONTROL, TRUE );
        send_vk( VK_LCONTROL, TRUE );
        send_vk( VK_RCONTROL, TRUE );
        send_vk( VK_MENU, TRUE );
        send_vk( VK_LMENU, TRUE );
        send_vk( VK_RMENU, TRUE );
    }
    else if (!lstrcmpA( a1, "ctrlq" ))
    {
        send_vk( VK_CONTROL, FALSE );
        tap( 'Q' );
        send_vk( VK_CONTROL, TRUE );
    }
    else if (!lstrcmpA( a1, "type" ) && a2[0])
        type_text( a2 );
    else if (!lstrcmpA( a1, "key" ) && a2[0])
    {
        if      (!lstrcmpA( a2, "enter" )) tap( VK_RETURN );
        else if (!lstrcmpA( a2, "down" ))  tap( VK_DOWN );
        else if (!lstrcmpA( a2, "up" ))    tap( VK_UP );
        else if (!lstrcmpA( a2, "left" ))  tap( VK_LEFT );
        else if (!lstrcmpA( a2, "right" )) tap( VK_RIGHT );
        else if (!lstrcmpA( a2, "esc" ))   tap( VK_ESCAPE );
        else if (!lstrcmpA( a2, "tab" ))   tap( VK_TAB );
        else if (!lstrcmpA( a2, "f1" ))    tap( VK_F1 );
        else ret = 1;
    }
    else if (!lstrcmpA( a1, "move" ) && a2[0] && a3[0])
        move_to( my_atoi( a2 ), my_atoi( a3 ) );
    else if (!lstrcmpA( a1, "click" ) && a2[0] && a3[0])
    {
        move_to( my_atoi( a2 ), my_atoi( a3 ) );
        btn( MOUSEEVENTF_LEFTDOWN );
        btn( MOUSEEVENTF_LEFTUP );
    }
    else if (!lstrcmpA( a1, "press" ) && a2[0] && a3[0])
    {   /* press and hold for 1500ms (probe GetCapture meanwhile) */
        move_to( my_atoi( a2 ), my_atoi( a3 ) );
        btn( MOUSEEVENTF_LEFTDOWN );
        Sleep( 1500 );
        btn( MOUSEEVENTF_LEFTUP );
    }
    else if (!lstrcmpA( a1, "dblclick" ) && a2[0] && a3[0])
    {
        move_to( my_atoi( a2 ), my_atoi( a3 ) );
        btn( MOUSEEVENTF_LEFTDOWN );
        btn( MOUSEEVENTF_LEFTUP );
        Sleep( 60 );
        btn( MOUSEEVENTF_LEFTDOWN );
        btn( MOUSEEVENTF_LEFTUP );
    }
    else if (!lstrcmpA( a1, "close" ))
    {
        if (live) PostMessageW( live, WM_CLOSE, 0, 0 );
        else ret = 1;
    }
    else ret = 1;

    ExitProcess( ret );
}
