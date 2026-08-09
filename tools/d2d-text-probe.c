/*
 * Measure whether Direct2D delivers DirectWrite's subpixel coverage to the
 * target, or averages it back into greyscale.
 *
 * Draws white text on an opaque black Direct2D bitmap target with ClearType
 * antialiasing, reads the result back, and reports how far the red and blue
 * channels sit from green across the pixels the text touched.
 *
 * Greyscale gives r == g == b in every pixel, so the "colour spread" is
 * exactly zero. Real subpixel rendering puts different coverage in each
 * channel, so the spread is not zero. Like the dwrite probe, the failing
 * value is a known constant and no reference image is needed.
 *
 * Build with scripts/build-win32-tools.sh, run under any Wine.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d2d1.h>
#include <dwrite.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    float emsize = argc > 1 ? (float)atof(argv[1]) : 32.0f;
    static const WCHAR sample[] = L"Handgloves Illinois 1080";
    D2D1_FACTORY_OPTIONS factory_opts = {D2D1_DEBUG_LEVEL_NONE};
    ID2D1Factory *d2d_factory = NULL;
    IDWriteFactory *dw_factory = NULL;
    IDWriteTextFormat *format = NULL;
    ID2D1RenderTarget *rt = NULL;
    ID2D1SolidColorBrush *brush = NULL;
    D2D1_RENDER_TARGET_PROPERTIES rt_desc;
    D2D1_COLOR_F white = {1.0f, 1.0f, 1.0f, 1.0f};
    D2D1_COLOR_F black = {0.0f, 0.0f, 0.0f, 1.0f};
    D2D1_RECT_F layout = {0.0f, 0.0f, 1200.0f, 200.0f};
    D2D1_SIZE_U size = {1200, 200};
    HDC hdc, memdc;
    HBITMAP dib, old;
    BITMAPINFO bi;
    void *bits = NULL;
    RECT bind_rect = {0, 0, 1200, 200};
    double spread_rb = 0.0;
    unsigned int touched = 0;
    unsigned int x, y;
    HRESULT hr;

    /* A DC render target keeps this free of swapchain and window variables:
     * the result lands in a DIB this program owns and can read directly. */
    hdc = GetDC(NULL);
    memdc = CreateCompatibleDC(hdc);
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = size.width;
    bi.bmiHeader.biHeight = -(LONG)size.height;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    dib = CreateDIBSection(memdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!dib || !bits) { printf("CreateDIBSection failed\n"); return 1; }
    old = SelectObject(memdc, dib);

    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory,
            &factory_opts, (void **)&d2d_factory);
    if (FAILED(hr)) { printf("D2D1CreateFactory failed %#lx\n", hr); return 1; }

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&dw_factory);
    if (FAILED(hr)) { printf("DWriteCreateFactory failed %#lx\n", hr); return 1; }

    memset(&rt_desc, 0, sizeof(rt_desc));
    rt_desc.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
    rt_desc.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    rt_desc.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    rt_desc.usage = D2D1_RENDER_TARGET_USAGE_NONE;

    hr = ID2D1Factory_CreateDCRenderTarget(d2d_factory, &rt_desc, (ID2D1DCRenderTarget **)&rt);
    if (FAILED(hr)) { printf("CreateDCRenderTarget failed %#lx\n", hr); return 1; }

    hr = ID2D1DCRenderTarget_BindDC((ID2D1DCRenderTarget *)rt, memdc, &bind_rect);
    if (FAILED(hr)) { printf("BindDC failed %#lx\n", hr); return 1; }

    hr = IDWriteFactory_CreateTextFormat(dw_factory, L"Tahoma", NULL, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, emsize, L"en-us", &format);
    if (FAILED(hr)) { printf("CreateTextFormat failed %#lx\n", hr); return 1; }

    ID2D1RenderTarget_BeginDraw(rt);
    ID2D1RenderTarget_Clear(rt, &black);
    /* With "default" the target's antialias mode is left alone, which is what
     * an ordinary application does: it is then the rendering params, not the
     * application, that decide whether text is subpixel. */
    if (!(argc > 2 && !strcmp(argv[2], "default")))
        ID2D1RenderTarget_SetTextAntialiasMode(rt, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    hr = ID2D1RenderTarget_CreateSolidColorBrush(rt, &white, NULL, &brush);
    if (FAILED(hr)) { printf("CreateSolidColorBrush failed %#lx\n", hr); return 1; }
    ID2D1RenderTarget_DrawText(rt, sample, ARRAYSIZE(sample) - 1, format, &layout,
            (ID2D1Brush *)brush, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
    hr = ID2D1RenderTarget_EndDraw(rt, NULL, NULL);
    if (FAILED(hr)) { printf("EndDraw failed %#lx\n", hr); return 1; }

    GdiFlush();

    for (y = 0; y < size.height; y++)
    {
        const BYTE *row = (const BYTE *)bits + (size_t)y * size.width * 4;

        for (x = 0; x < size.width; x++)
        {
            int b = row[x * 4 + 0], g = row[x * 4 + 1], r = row[x * 4 + 2];

            if (!r && !g && !b)
                continue;
            touched++;
            spread_rb += abs(r - g) + abs(b - g);
        }
    }

    printf("em size      : %.0f\n", emsize);
    printf("lit pixels   : %u\n", touched);
    printf("colour spread: %.0f total, %.3f per lit pixel\n", spread_rb,
            touched ? spread_rb / touched : 0.0);
    if (spread_rb == 0.0)
        printf("verdict      : GREYSCALE reaching the target (subpixel averaged away)\n");
    else
        printf("verdict      : SUBPIXEL reaching the target\n");

    SelectObject(memdc, old);
    DeleteObject(dib);
    DeleteDC(memdc);
    ReleaseDC(NULL, hdc);
    return 0;
}
