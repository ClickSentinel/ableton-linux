/*
 * Measure whether DirectWrite's ClearType texture carries real subpixel
 * coverage, or one greyscale value copied into all three subpixels.
 *
 * Renders a glyph run through IDWriteGlyphRunAnalysis, asks for a
 * DWRITE_TEXTURE_CLEARTYPE_3x1 alpha texture, and compares each covered
 * pixel's RGB coverage triple. Greyscale replicated across three channels
 * gives exactly R == G == B for every pixel, whatever the text or size.
 * Genuine subpixel rendering does not: the channels differ wherever a stem
 * lands between pixel boundaries. Channel totals are only diagnostic; a
 * symmetric LCD filter can give equal totals even when individual triples
 * differ.
 *
 * So the test needs no reference image and no Windows machine to be
 * informative: the "before" value is a known constant.
 *
 * Build with scripts/build-win32-tools.sh, run under any Wine.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <dwrite.h>
#include <stdio.h>
#include <stdlib.h>

static const WCHAR *sample = L"Handgloves Illinois 1080";

int main(int argc, char **argv)
{
    /* Em size matters: a face with embedded bitmaps returns one at small
     * sizes, and an embedded bitmap has no subpixel coverage to carry. */
    float emsize = argc > 1 ? (float)atof(argv[1]) : 24.0f;
    IDWriteFactory *factory = NULL;
    IDWriteFontFace *fontface = NULL;
    IDWriteFontCollection *collection = NULL;
    IDWriteFontFamily *family = NULL;
    IDWriteFont *font = NULL;
    IDWriteGlyphRunAnalysis *analysis = NULL;
    DWRITE_GLYPH_RUN run;
    DWRITE_GLYPH_OFFSET *offsets = NULL;
    UINT16 *indices = NULL;
    UINT32 *codepoints = NULL;
    FLOAT *advances = NULL;
    UINT32 i, count, index;
    BOOL exists = FALSE;
    RECT bounds;
    BYTE *texture = NULL;
    SIZE_T size, covered = 0, differing = 0;
    double ink[3] = {0.0, 0.0, 0.0};
    int width, height, x, y;
    HRESULT hr;

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory);
    if (FAILED(hr)) { printf("DWriteCreateFactory failed %#lx\n", hr); return 1; }

    hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    if (FAILED(hr)) { printf("GetSystemFontCollection failed %#lx\n", hr); return 1; }

    hr = IDWriteFontCollection_FindFamilyName(collection, L"Tahoma", &index, &exists);
    if (FAILED(hr) || !exists)
    {
        /* Any installed family answers the question equally well. */
        index = 0;
        printf("note: Tahoma not found, using family 0\n");
    }

    hr = IDWriteFontCollection_GetFontFamily(collection, index, &family);
    if (FAILED(hr)) { printf("GetFontFamily failed %#lx\n", hr); return 1; }

    hr = IDWriteFontFamily_GetFirstMatchingFont(family, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &font);
    if (FAILED(hr)) { printf("GetFirstMatchingFont failed %#lx\n", hr); return 1; }

    hr = IDWriteFont_CreateFontFace(font, &fontface);
    if (FAILED(hr)) { printf("CreateFontFace failed %#lx\n", hr); return 1; }

    count = lstrlenW(sample);
    codepoints = calloc(count, sizeof(*codepoints));
    indices = calloc(count, sizeof(*indices));
    advances = calloc(count, sizeof(*advances));
    offsets = calloc(count, sizeof(*offsets));
    if (!codepoints || !indices || !advances || !offsets) return 1;

    for (i = 0; i < count; i++)
        codepoints[i] = sample[i];

    hr = IDWriteFontFace_GetGlyphIndices(fontface, codepoints, count, indices);
    if (FAILED(hr)) { printf("GetGlyphIndices failed %#lx\n", hr); return 1; }

    memset(&run, 0, sizeof(run));
    run.fontFace = fontface;
    run.fontEmSize = emsize;
    run.glyphCount = count;
    run.glyphIndices = indices;
    run.glyphAdvances = advances;
    run.glyphOffsets = offsets;

    /* Advances come from the face so the glyphs do not pile up at the origin. */
    {
        DWRITE_GLYPH_METRICS *metrics = calloc(count, sizeof(*metrics));
        DWRITE_FONT_METRICS face_metrics;

        if (!metrics) return 1;
        IDWriteFontFace_GetMetrics(fontface, &face_metrics);
        if (SUCCEEDED(IDWriteFontFace_GetDesignGlyphMetrics(fontface, indices, count, metrics, FALSE)))
        {
            for (i = 0; i < count; i++)
                advances[i] = metrics[i].advanceWidth * run.fontEmSize / face_metrics.designUnitsPerEm;
        }
        free(metrics);
    }

    hr = IDWriteFactory_CreateGlyphRunAnalysis(factory, &run, 1.0f, NULL,
            DWRITE_RENDERING_MODE_CLEARTYPE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            0.0f, 0.0f, &analysis);
    if (FAILED(hr)) { printf("CreateGlyphRunAnalysis failed %#lx\n", hr); return 1; }

    hr = IDWriteGlyphRunAnalysis_GetAlphaTextureBounds(analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds);
    if (FAILED(hr)) { printf("GetAlphaTextureBounds failed %#lx\n", hr); return 1; }

    width = bounds.right - bounds.left;
    height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0) { printf("empty texture bounds\n"); return 1; }

    size = (SIZE_T)width * height * 3;
    if (!(texture = calloc(1, size))) return 1;

    hr = IDWriteGlyphRunAnalysis_CreateAlphaTexture(analysis, DWRITE_TEXTURE_CLEARTYPE_3x1,
            &bounds, texture, size);
    if (FAILED(hr)) { printf("CreateAlphaTexture failed %#lx\n", hr); return 1; }

    for (y = 0; y < height; y++)
    {
        const BYTE *row = texture + (SIZE_T)y * width * 3;

        for (x = 0; x < width; x++)
        {
            const BYTE *pixel = row + x * 3;

            if (pixel[0] || pixel[1] || pixel[2]) covered++;
            if (pixel[0] != pixel[1] || pixel[1] != pixel[2]) differing++;
            for (i = 0; i < 3; i++)
                ink[i] += pixel[i];
        }
    }

    printf("texture   : %dx%d pixels, %llu subpixel samples\n", width, height,
            (unsigned long long)size);
    printf("ink R/G/B : %.0f / %.0f / %.0f\n", ink[0], ink[1], ink[2]);
    printf("RGB triples: %llu / %llu covered triples differ\n", (unsigned long long)differing,
            (unsigned long long)covered);
    if (!differing)
        printf("verdict   : GREYSCALE replicated across three channels (no subpixel resolution)\n");
    else
        printf("verdict   : SUBPIXEL, %.2f%% of covered RGB triples differ\n",
                covered ? 100.0 * differing / covered : 0.0);

    return 0;
}
