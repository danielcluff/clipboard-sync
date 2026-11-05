#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include "bridge.h"
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <wchar.h>
#ifndef CS_STARTUP_KEY
#error This test must use an isolated registry key, never the actual Run key.
#endif
void cs_notice(const char *title, const char *message) {
    fprintf(stderr, "%s: %s\n", title, message);
}
int main(void) {
    HKEY key;
    /* The build supplies a test-only key; no real login settings are changed. */
    RegDeleteTreeW(HKEY_CURRENT_USER, CS_STARTUP_KEY);
    assert(cs_startup_status() == 0);
    assert(cs_startup_set_enabled(0));
    assert(cs_startup_set_enabled(1));
    assert(cs_startup_status() == 1);
    assert(cs_startup_set_enabled(1));
    assert(RegOpenKeyExW(HKEY_CURRENT_USER, CS_STARTUP_KEY, 0, KEY_ALL_ACCESS, &key) ==
           ERROR_SUCCESS);
    WCHAR actual[261], executable[261], expected[264];
    DWORD bytes = sizeof(actual), type;
    assert(RegQueryValueExW(key, L"Clipboard Sync", NULL, &type, (BYTE *)actual, &bytes) ==
           ERROR_SUCCESS);
    assert(type == REG_SZ);
    assert(GetModuleFileNameW(NULL, executable, 261));
    swprintf(expected, 264, L"\"%ls\"", executable);
    assert(wcscmp(actual, expected) == 0);
    // Other startup values must survive turning this application off.
    const WCHAR other[] = L"Another app";
    assert(RegSetValueExW(key, L"Other app", 0, REG_SZ, (const BYTE *)other, sizeof(other)) ==
           ERROR_SUCCESS);
    assert(cs_startup_set_enabled(0));
    assert(cs_startup_status() == 0);
    bytes = sizeof(actual);
    assert(RegQueryValueExW(key, L"Other app", NULL, &type, (BYTE *)actual, &bytes) ==
           ERROR_SUCCESS);
    // A registration pointing at an old location must be replaced on enable.
    const WCHAR old[] = L"\"C:\\Old Location\\clipboard-sync.exe\"";
    assert(RegSetValueExW(key, L"Clipboard Sync", 0, REG_SZ, (const BYTE *)old, sizeof(old)) ==
           ERROR_SUCCESS);
    assert(cs_startup_status() == 0);
    cs_startup_toggle();
    assert(cs_startup_status() == 1);
    cs_startup_toggle();
    assert(cs_startup_status() == 0);
    RegCloseKey(key);
    assert(RegDeleteTreeW(HKEY_CURRENT_USER, CS_STARTUP_KEY) == ERROR_SUCCESS);
    puts("startup: registration, quoted paths, disable, moved app and unrelated values passed");
    return 0;
}
