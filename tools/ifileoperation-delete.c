/* ifileoperation-delete.c -- reproduce IFileOperation::DeleteItem.
 *
 * Usage: ifileoperation-delete.exe PATH [modern]
 *
 * The optional "modern" argument uses FOFX_RECYCLEONDELETE, as Live does.
 * Without it, the probe uses the older FOF_ALLOWUNDO recycle flag. The probe
 * succeeds only if DeleteItem and PerformOperations succeed, the operation is
 * not aborted, and PATH no longer exists at its original location.
 *
 * Build against a Wine source tree:
 *   winegcc -b x86_64-windows -mconsole -o ifileoperation-delete.exe \
 *       ifileoperation-delete.c -lole32 -lshell32 -luuid
 */

#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>

static void print_hr(const char *name, HRESULT hr)
{
    printf("%s=0x%08lx\n", name, (unsigned long)hr);
}

int main(int argc, char **argv)
{
    IFileOperation *operation = NULL;
    IShellItem *item = NULL;
    WCHAR path[MAX_PATH + 1];
    DWORD flags = FOF_ALLOWUNDO | FOF_NO_UI;
    DWORD error;
    BOOL aborted = FALSE;
    HRESULT hr;
    int ret = 1;

    if (argc < 2 || argc > 3)
    {
        fprintf(stderr, "usage: ifileoperation-delete.exe PATH [modern]\n");
        return 2;
    }
    if (argc == 3)
    {
        if (strcmp(argv[2], "modern"))
        {
            fprintf(stderr, "unknown mode: %s\n", argv[2]);
            return 2;
        }
        flags = FOFX_RECYCLEONDELETE | FOF_NO_UI;
    }

    if (!MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, path, MAX_PATH + 1))
    {
        fprintf(stderr, "path conversion failed: %lu\n", (unsigned long)GetLastError());
        return 2;
    }
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES)
    {
        fprintf(stderr, "path does not exist: %lu\n", (unsigned long)GetLastError());
        return 2;
    }

    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    print_hr("CoInitializeEx", hr);
    if (FAILED(hr)) return 1;

    hr = CoCreateInstance(&CLSID_FileOperation, NULL, CLSCTX_INPROC_SERVER,
            &IID_IFileOperation, (void **)&operation);
    print_hr("CoCreateInstance", hr);
    if (FAILED(hr)) goto done;

    hr = SHCreateItemFromParsingName(path, NULL, &IID_IShellItem, (void **)&item);
    print_hr("SHCreateItemFromParsingName", hr);
    if (FAILED(hr)) goto done;

    hr = IFileOperation_SetOperationFlags(operation, flags);
    print_hr("SetOperationFlags", hr);
    if (FAILED(hr)) goto done;

    hr = IFileOperation_DeleteItem(operation, item, NULL);
    print_hr("DeleteItem", hr);
    if (FAILED(hr)) goto done;

    hr = IFileOperation_PerformOperations(operation);
    print_hr("PerformOperations", hr);
    if (FAILED(hr)) goto done;

    hr = IFileOperation_GetAnyOperationsAborted(operation, &aborted);
    print_hr("GetAnyOperationsAborted", hr);
    printf("aborted=%u\n", aborted);
    if (FAILED(hr) || aborted) goto done;

    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES)
    {
        fprintf(stderr, "path still exists after successful operation\n");
        goto done;
    }
    error = GetLastError();
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
    {
        fprintf(stderr, "path check failed: %lu\n", (unsigned long)error);
        goto done;
    }

    ret = 0;

done:
    if (item) IShellItem_Release(item);
    if (operation) IFileOperation_Release(operation);
    CoUninitialize();
    return ret;
}
