/*
 * Measure whether GDI text is subpixel-rendered.
 *
 * Native Win32 menus, dialogs and controls draw through GDI, not Direct2D, so
 * they are governed by win32u's font smoothing rather than by DirectWrite's
 * rendering params. This draws text into a DIB with DrawTextW and reports how
 * far red and blue sit from green over the lit pixels, the same measure the
 * Direct2D probe uses: greyscale gives exactly zero.
 *
 * Build with scripts/build-win32-tools.sh, run under any Wine.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int height = argc > 1 ? atoi(argv[1]) : 32;
    static const WCHAR sample[] = L"Handgloves Illinois 1080";
    BITMAPINFO bi;
    void *bits = NULL;
    HDC memdc;
    HBITMAP dib, oldbm;
    HFONT font, oldfont;
    RECT rect = {0, 0, 1200, 200};
    NONCLIENTMETRICSW ncm;
    double spread = 0.0;
    unsigned int touched = 0, x, y;
    UINT smoothing_type = 0;
    BOOL smoothing = FALSE;

    memdc = CreateCompatibleDC(NULL);
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = rect.right;
    bi.bmiHeader.biHeight = -rect.bottom;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    dib = CreateDIBSection(memdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!dib || !bits) { printf("CreateDIBSection failed\n"); return 1; }
    oldbm = SelectObject(memdc, dib);

    /* Black background, white text: same arrangement as the Direct2D probe. */
    {
        HBRUSH black = CreateSolidBrush(RGB(0, 0, 0));
        FillRect(memdc, &rect, black);
        DeleteObject(black);
    }

    /* A named TrueType face, not the non-client metrics font: in a bare
     * prefix that resolves to Wine's built-in "System" bitmap font, which has
     * no outlines and so is never antialiased, and the probe then reports
     * greyscale whatever the smoothing settings say. */
    memset(&ncm, 0, sizeof(ncm));
    ncm.cbSize = sizeof(ncm);
    {
        LOGFONTW lf;

        memset(&lf, 0, sizeof(lf));
        lf.lfHeight = -height;
        lf.lfWeight = FW_NORMAL;
        lf.lfCharSet = DEFAULT_CHARSET;
        lf.lfQuality = DEFAULT_QUALITY;
        lstrcpyW(lf.lfFaceName, argc > 2 ? L"Arial" : L"Tahoma");
        font = CreateFontIndirectW(&lf);
    }

    oldfont = SelectObject(memdc, font);
    SetTextColor(memdc, RGB(255, 255, 255));
    SetBkMode(memdc, TRANSPARENT);
    DrawTextW(memdc, sample, ARRAYSIZE(sample) - 1, &rect, DT_LEFT | DT_TOP | DT_SINGLELINE);
    GdiFlush();

    for (y = 0; y < (unsigned int)rect.bottom; y++)
    {
        const BYTE *row = (const BYTE *)bits + (size_t)y * rect.right * 4;

        for (x = 0; x < (unsigned int)rect.right; x++)
        {
            int b = row[x * 4 + 0], g = row[x * 4 + 1], r = row[x * 4 + 2];

            if (!r && !g && !b)
                continue;
            touched++;
            spread += abs(r - g) + abs(b - g);
        }
    }

    SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0);
    SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &smoothing_type, 0);

    printf("font height  : %d\n", height);
    printf("smoothing    : enabled=%d type=%u (2 = ClearType)\n", smoothing, smoothing_type);
    printf("lit pixels   : %u\n", touched);
    printf("colour spread: %.0f total, %.3f per lit pixel\n", spread,
            touched ? spread / touched : 0.0);
    printf("verdict      : %s\n", spread == 0.0 ? "GREYSCALE" : "SUBPIXEL");

    SelectObject(memdc, oldfont);
    if (font != GetStockObject(DEFAULT_GUI_FONT)) DeleteObject(font);
    SelectObject(memdc, oldbm);
    DeleteObject(dib);
    DeleteDC(memdc);
    return 0;
}
