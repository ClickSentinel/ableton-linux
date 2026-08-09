/* Repro for the Alt+number menu-bar activation divergence (Mike Verdone,
 * 2026-08-06). A window whose wndproc swallows WM_SYSKEYDOWN/WM_SYSCHAR for
 * Alt+4 -- the way Live handles its "Move Focus to the Device View"
 * shortcut -- then watches what DefWindowProc does when Alt is released.
 *
 * Modes:
 *   swallow  - handle Alt+4 like Live does (return 0, no DefWindowProc)
 *   pass     - pass everything to DefWindowProc (app with no Alt+4 binding)
 *
 * Expected on real Windows: swallow mode does not enter menu mode. Pass mode
 * can make a short mnemonic lookup, but it does not leave the menu armed for
 * the next key. Win32k tracks "another key was pressed while Alt was down"
 * in the input queue (QF_FMENUSTATUSBREAK), independent of what the app does
 * with the messages.
 *
 * Unpatched Wine tracks that state in a static (menu_sys_key) updated only
 * when messages reach DefWindowProc, so swallow mode leaves it armed. The
 * program returns a non-zero status when the regression or a control fails.
 */

#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int swallow_mode;
static DWORD t0;

enum test_stage
{
    STAGE_NONE,
    STAGE_ALT4_TYPING,
    STAGE_ALT4_TYPING_FOLLOWUP,
    STAGE_ALT4_ALT_FIRST,
    STAGE_ALT4_ALT_FIRST_FOLLOWUP,
    STAGE_ALT_CLICK,
    STAGE_ALT_CLICK_FOLLOWUP,
    STAGE_ALT_F,
    STAGE_BARE_ALT
};

static LONG stage;
static LONG prohibited_menu_events;
static LONG alt_f_keymenu;
static LONG alt_f_menu_loop;
static LONG alt_f_popup;
static LONG bare_alt_keymenu;
static LONG bare_alt_menu_loop;
static LONG alt4_typing_seen;
static LONG alt4_alt_first_seen;
static LONG alt_click_seen;
static LONG injection_failures;

static void say( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    printf( "[%5lu] ", (unsigned long)(GetTickCount() - t0) );
    vprintf( fmt, ap );
    printf( "\n" );
    fflush( stdout );
    va_end( ap );
}

static void set_stage( enum test_stage next )
{
    InterlockedExchange( &stage, next );
}

static void record_menu_event( const char *name )
{
    LONG current = InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE );
    int prohibited = current == STAGE_ALT4_TYPING_FOLLOWUP ||
                     current == STAGE_ALT4_ALT_FIRST_FOLLOWUP ||
                     current == STAGE_ALT_CLICK || current == STAGE_ALT_CLICK_FOLLOWUP ||
                     (swallow_mode && (current == STAGE_ALT4_TYPING ||
                                      current == STAGE_ALT4_ALT_FIRST));

    if (prohibited)
    {
        InterlockedIncrement( &prohibited_menu_events );
        say( "PROHIBITED menu event during stage %d: %s", (int)current, name );
    }
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_SYSKEYDOWN:
        say( "WM_SYSKEYDOWN wp=%02x alt=%d", (UINT)wp, (lp & (1 << 29)) != 0 );
        if (wp == '4' && InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_ALT4_TYPING)
            InterlockedIncrement( &alt4_typing_seen );
        if (wp == '4' && InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_ALT4_ALT_FIRST)
            InterlockedIncrement( &alt4_alt_first_seen );
        if (swallow_mode && wp == '4') { say( "  -> swallowed (app handled Alt+4)" ); return 0; }
        break;
    case WM_SYSKEYUP:
        say( "WM_SYSKEYUP   wp=%02x", (UINT)wp );
        if (swallow_mode && wp == '4') { say( "  -> swallowed" ); return 0; }
        break;
    case WM_KEYDOWN:
        say( "WM_KEYDOWN    wp=%02x", (UINT)wp );
        break;
    case WM_KEYUP:
        say( "WM_KEYUP      wp=%02x", (UINT)wp );
        break;
    case WM_SYSCHAR:
        say( "WM_SYSCHAR    wp=%02x ('%c')", (UINT)wp, (char)wp );
        if (swallow_mode && wp == '4') { say( "  -> swallowed" ); return 0; }
        break;
    case WM_LBUTTONDOWN:
        say( "WM_LBUTTONDOWN captured=%d", GetCapture() == hwnd );
        if (InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_ALT_CLICK)
            InterlockedIncrement( &alt_click_seen );
        if (swallow_mode) { say( "  -> swallowed (app handled Alt+click)" ); return 0; }
        break;
    case WM_LBUTTONUP:
        say( "WM_LBUTTONUP   captured=%d", GetCapture() == hwnd );
        if (swallow_mode) { say( "  -> swallowed" ); return 0; }
        break;
    case WM_APP:
        SetCapture( hwnd );
        say( "SetCapture=%d (want 1)", GetCapture() == hwnd );
        if (GetCapture() != hwnd) InterlockedIncrement( &injection_failures );
        return 0;
    case WM_APP + 1:
        ReleaseCapture();
        return 0;
    case WM_SYSCOMMAND:
        if ((wp & 0xfff0) == SC_KEYMENU)
        {
            LONG current = InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE );
            say( "WM_SYSCOMMAND SC_KEYMENU ch=%02lx  <=== menu-bar activation", (ULONG_PTR)lp );
            record_menu_event( "SC_KEYMENU" );
            if (current == STAGE_ALT_F && (lp == 'F' || lp == 'f'))
                InterlockedIncrement( &alt_f_keymenu );
            if (current == STAGE_BARE_ALT && !lp)
                InterlockedIncrement( &bare_alt_keymenu );
        }
        break;
    case WM_ENTERMENULOOP:
        say( "WM_ENTERMENULOOP  <=== menu mode entered" );
        record_menu_event( "WM_ENTERMENULOOP" );
        if (InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_ALT_F)
            InterlockedIncrement( &alt_f_menu_loop );
        if (InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_BARE_ALT)
            InterlockedIncrement( &bare_alt_menu_loop );
        break;
    case WM_EXITMENULOOP:
        say( "WM_EXITMENULOOP" );
        break;
    case WM_INITMENUPOPUP:
        say( "WM_INITMENUPOPUP  <=== a dropdown opened" );
        record_menu_event( "WM_INITMENUPOPUP" );
        if (InterlockedCompareExchange( &stage, STAGE_NONE, STAGE_NONE ) == STAGE_ALT_F)
            InterlockedIncrement( &alt_f_popup );
        break;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void key( WORD vk, DWORD flags )
{
    INPUT in = { .type = INPUT_KEYBOARD };
    in.ki.wVk = vk;
    in.ki.wScan = MapVirtualKeyA( vk, MAPVK_VK_TO_VSC );
    in.ki.dwFlags = flags;
    if (SendInput( 1, &in, sizeof(in) ) != 1)
    {
        say( "SendInput key failed: %lu", (unsigned long)GetLastError() );
        InterlockedIncrement( &injection_failures );
    }
    Sleep( 30 );
}

static void button( DWORD flags )
{
    INPUT in = { .type = INPUT_MOUSE };
    in.mi.dwFlags = flags;
    if (SendInput( 1, &in, sizeof(in) ) != 1)
    {
        say( "SendInput mouse failed: %lu", (unsigned long)GetLastError() );
        InterlockedIncrement( &injection_failures );
    }
    Sleep( 30 );
}

static void focus_window( HWND hwnd )
{
    DWORD self = GetCurrentThreadId();
    DWORD owner = GetWindowThreadProcessId( hwnd, NULL );
    DWORD foreground_owner;
    HWND foreground;
    BOOL owner_attached;
    BOOL foreground_attached;
    int i;

    for (i = 0; i < 50 && GetForegroundWindow() != hwnd; i++)
    {
        foreground = GetForegroundWindow();
        foreground_owner = foreground ? GetWindowThreadProcessId( foreground, NULL ) : 0;
        owner_attached = owner != self && AttachThreadInput( self, owner, TRUE );
        foreground_attached = foreground_owner && foreground_owner != self &&
                              foreground_owner != owner &&
                              AttachThreadInput( self, foreground_owner, TRUE );
        BringWindowToTop( hwnd );
        SetForegroundWindow( hwnd );
        SetFocus( hwnd );
        if (foreground_attached) AttachThreadInput( self, foreground_owner, FALSE );
        if (owner_attached) AttachThreadInput( self, owner, FALSE );
        Sleep( 100 );
    }
    say( "foreground=%d (want 1)", GetForegroundWindow() == hwnd );
    if (GetForegroundWindow() != hwnd) InterlockedIncrement( &injection_failures );
}

static DWORD WINAPI inject( void *arg )
{
    HWND hwnd = arg;
    RECT rect;

    Sleep( 400 );
    focus_window( hwnd );
    say( "--- inject: Alt down, 4 down, 4 up, Alt up (typing-order release)" );
    set_stage( STAGE_ALT4_TYPING );
    key( VK_MENU, 0 );
    key( '4', 0 );
    key( '4', KEYEVENTF_KEYUP );
    key( VK_MENU, KEYEVENTF_KEYUP );

    Sleep( 600 );
    focus_window( hwnd );
    say( "--- inject: press F (does a menu open?)" );
    set_stage( STAGE_ALT4_TYPING_FOLLOWUP );
    key( 'F', 0 );
    key( 'F', KEYEVENTF_KEYUP );

    Sleep( 600 );
    say( "--- inject: Esc, Esc (leave any menu mode)" );
    set_stage( STAGE_NONE );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );

    Sleep( 400 );
    focus_window( hwnd );
    say( "--- inject: Alt down, 4 down, Alt up, 4 up (alt-first release)" );
    set_stage( STAGE_ALT4_ALT_FIRST );
    key( VK_MENU, 0 );
    key( '4', 0 );
    key( VK_MENU, KEYEVENTF_KEYUP );
    key( '4', KEYEVENTF_KEYUP );

    Sleep( 600 );
    focus_window( hwnd );
    say( "--- inject: press F again" );
    set_stage( STAGE_ALT4_ALT_FIRST_FOLLOWUP );
    key( 'F', 0 );
    key( 'F', KEYEVENTF_KEYUP );

    Sleep( 600 );
    set_stage( STAGE_NONE );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );

    Sleep( 400 );
    focus_window( hwnd );
    say( "--- inject: Alt+F (mnemonic, File menu must open)" );
    set_stage( STAGE_ALT_F );
    key( VK_MENU, 0 );
    key( 'F', 0 );
    key( 'F', KEYEVENTF_KEYUP );
    key( VK_MENU, KEYEVENTF_KEYUP );

    Sleep( 600 );
    set_stage( STAGE_NONE );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );

    Sleep( 400 );
    focus_window( hwnd );
    say( "--- inject: bare Alt press+release (menu bar must arm)" );
    set_stage( STAGE_BARE_ALT );
    key( VK_MENU, 0 );
    key( VK_MENU, KEYEVENTF_KEYUP );

    Sleep( 600 );
    set_stage( STAGE_NONE );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );
    Sleep( 200 );

    Sleep( 400 );
    focus_window( hwnd );
    say( "--- inject: Alt down, captured left click swallowed, Alt up" );
    set_stage( STAGE_ALT_CLICK );
    GetWindowRect( hwnd, &rect );
    SetCursorPos( (rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2 );
    PostMessageA( hwnd, WM_APP, 0, 0 );
    Sleep( 100 );
    key( VK_MENU, 0 );
    button( MOUSEEVENTF_LEFTDOWN );
    Sleep( 100 );
    button( MOUSEEVENTF_LEFTUP );
    Sleep( 100 );
    PostMessageA( hwnd, WM_APP + 1, 0, 0 );
    key( VK_MENU, KEYEVENTF_KEYUP );

    Sleep( 600 );
    focus_window( hwnd );
    say( "--- inject: press F after Alt+click (does a menu open?)" );
    set_stage( STAGE_ALT_CLICK_FOLLOWUP );
    key( 'F', 0 );
    key( 'F', KEYEVENTF_KEYUP );

    Sleep( 600 );
    set_stage( STAGE_NONE );
    key( VK_ESCAPE, 0 );
    key( VK_ESCAPE, KEYEVENTF_KEYUP );
    Sleep( 200 );
    PostMessageA( hwnd, WM_CLOSE, 0, 0 );
    return 0;
}

int main( int argc, char **argv )
{
    WNDCLASSA wc = { .lpfnWndProc = wndproc, .lpszClassName = "altnum_test" };
    HMENU bar = CreateMenu(), file = CreatePopupMenu(), edit = CreatePopupMenu();
    HWND hwnd;
    HANDLE thread;
    MSG msg;
    BOOL ret;
    int failures = 0;

    if (argc != 2 || (strcmp( argv[1], "swallow" ) && strcmp( argv[1], "pass" )))
    {
        fprintf( stderr, "usage: %s swallow|pass\n", argv[0] );
        return 2;
    }
    swallow_mode = !strcmp( argv[1], "swallow" );
    t0 = GetTickCount();
    say( "mode: %s", swallow_mode ? "swallow (Live-like)" : "pass (DefWindowProc sees everything)" );

    if (!RegisterClassA( &wc ))
    {
        fprintf( stderr, "RegisterClass failed: %lu\n", (unsigned long)GetLastError() );
        return 2;
    }
    if (!bar || !file || !edit ||
        !AppendMenuA( file, MF_STRING, 100, "&Open" ) ||
        !AppendMenuA( edit, MF_STRING, 101, "&Copy" ) ||
        !AppendMenuA( bar, MF_POPUP, (UINT_PTR)file, "&File" ) ||
        !AppendMenuA( bar, MF_POPUP, (UINT_PTR)edit, "&Edit" ))
    {
        fprintf( stderr, "menu setup failed: %lu\n", (unsigned long)GetLastError() );
        return 2;
    }

    hwnd = CreateWindowA( "altnum_test", "altnum", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          100, 100, 400, 300, 0, bar, 0, 0 );
    if (!hwnd)
    {
        fprintf( stderr, "CreateWindow failed: %lu\n", (unsigned long)GetLastError() );
        return 2;
    }
    SetForegroundWindow( hwnd );
    if (!(thread = CreateThread( NULL, 0, inject, hwnd, 0, NULL )))
    {
        fprintf( stderr, "CreateThread failed: %lu\n", (unsigned long)GetLastError() );
        return 2;
    }
    CloseHandle( thread );

    while ((ret = GetMessageA( &msg, 0, 0, 0 )) > 0)
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
    if (ret == -1)
    {
        fprintf( stderr, "GetMessage failed: %lu\n", (unsigned long)GetLastError() );
        return 2;
    }
    printf( "RESULT prohibited=%ld alt4_seen={typing:%ld,alt_first:%ld} "
            "alt_click_seen=%ld alt_f={keymenu:%ld,loop:%ld,popup:%ld} "
            "bare_alt={keymenu:%ld,loop:%ld} injection_failures=%ld\n",
            (long)prohibited_menu_events, (long)alt4_typing_seen,
            (long)alt4_alt_first_seen, (long)alt_click_seen, (long)alt_f_keymenu,
            (long)alt_f_menu_loop, (long)alt_f_popup, (long)bare_alt_keymenu,
            (long)bare_alt_menu_loop, (long)injection_failures );
    if (prohibited_menu_events) failures++;
    if (!alt4_typing_seen || !alt4_alt_first_seen || !alt_click_seen) failures++;
    if (!alt_f_keymenu || !alt_f_menu_loop || !alt_f_popup) failures++;
    if (!bare_alt_keymenu || !bare_alt_menu_loop) failures++;
    if (injection_failures) failures++;
    if (failures)
    {
        fprintf( stderr, "FAIL: %d regression requirement%s failed\n",
                 failures, failures == 1 ? "" : "s" );
        return 1;
    }
    say( "PASS" );
    return 0;
}
