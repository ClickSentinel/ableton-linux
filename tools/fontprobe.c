/* fontprobe - list the font families Wine actually enumerates, the same way
 * Max for Live does.
 *
 * Max builds its own font list from EnumFontFamiliesEx and matches requested
 * typeface names against it. That means FontSubstitutes registry aliases are
 * invisible to Max, and font files dropped into drive_c/windows/Fonts are only
 * visible once registered under
 * HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts.
 *
 * This probe answers "would Max find font X?" without launching Live.
 *
 *   x86_64-w64-mingw32-gcc -O2 -o fontprobe.exe fontprobe.c -lgdi32
 *   wine fontprobe.exe                # print count + every family
 *   wine fontprobe.exe "Bitstream Vera Sans" Geneva Menlo
 *                                     # exit 1 if any named family is absent
 *
 * See notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

#define MAX_FAMILIES 4096

static char families[MAX_FAMILIES][LF_FACESIZE];
static int  family_count;

static int seen(const char *name)
{
    for (int i = 0; i < family_count; i++)
        if (_stricmp(families[i], name) == 0) return 1;
    return 0;
}

static int CALLBACK cb(const LOGFONTA *lf, const TEXTMETRICA *tm,
                       DWORD type, LPARAM param)
{
    (void)tm; (void)type; (void)param;
    /* Skip the vertical-writing aliases Wine prefixes with '@'. */
    if (lf->lfFaceName[0] == '@') return 1;
    if (family_count < MAX_FAMILIES && !seen(lf->lfFaceName)) {
        strncpy(families[family_count], lf->lfFaceName, LF_FACESIZE - 1);
        families[family_count][LF_FACESIZE - 1] = '\0';
        family_count++;
    }
    return 1;
}

int main(int argc, char **argv)
{
    HDC dc = GetDC(NULL);
    LOGFONTA lf;

    memset(&lf, 0, sizeof(lf));
    lf.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExA(dc, &lf, (FONTENUMPROCA)cb, 0, 0);
    ReleaseDC(NULL, dc);

    if (argc < 2) {
        printf("%d families enumerated\n", family_count);
        for (int i = 0; i < family_count; i++)
            printf("  %s\n", families[i]);
        return 0;
    }

    int missing = 0;
    printf("%d families enumerated\n", family_count);
    for (int i = 1; i < argc; i++) {
        int ok = seen(argv[i]);
        printf("  %-32s %s\n", argv[i], ok ? "FOUND" : "MISSING");
        if (!ok) missing = 1;
    }
    return missing;
}
