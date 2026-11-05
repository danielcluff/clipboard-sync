#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include "bridge.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
/* Per-user registration; never touch machine-wide or other applications' values. */
#ifndef CS_STARTUP_KEY
#define CS_STARTUP_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#endif
static const WCHAR value_name[] = L"Clipboard Sync";
static int startup_command(WCHAR out[261]) {
    WCHAR executable[261];
    DWORD n = GetModuleFileNameW(NULL, executable, 261);
    // Run commands are limited to 260 characters, including the surrounding quotes.
    if (!n || n > 258) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        return 0;
    }
    out[0] = L'"';
    memcpy(out + 1, executable, n * sizeof(WCHAR));
    out[n + 1] = L'"';
    out[n + 2] = 0;
    return 1;
}
int cs_startup_status(void) {
    WCHAR expected[261], value[261];
    if (!startup_command(expected))
        return -1;
    HKEY key;
    LONG error = RegOpenKeyExW(HKEY_CURRENT_USER, CS_STARTUP_KEY, 0, KEY_QUERY_VALUE, &key);
    if (error == ERROR_FILE_NOT_FOUND)
        return 0;
    if (error != ERROR_SUCCESS) {
        SetLastError((DWORD)error);
        return -1;
    }
    DWORD type = 0, bytes = sizeof(value);
    error = RegQueryValueExW(key, value_name, NULL, &type, (BYTE *)value, &bytes);
    RegCloseKey(key);
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_MORE_DATA)
        return 0;
    if (error != ERROR_SUCCESS) {
        SetLastError((DWORD)error);
        return -1;
    }
    if (type != REG_SZ || bytes < sizeof(WCHAR) || bytes % sizeof(WCHAR) ||
        value[bytes / sizeof(WCHAR) - 1] != 0)
        return 0;
    return _wcsicmp(value, expected) == 0;
}
int cs_startup_set_enabled(int enabled) {
    HKEY key;
    LONG error;
    if (enabled) {
        WCHAR command[261];
        if (!startup_command(command))
            return 0;
        error = RegCreateKeyExW(HKEY_CURRENT_USER, CS_STARTUP_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL,
                                &key, NULL);
        if (error == ERROR_SUCCESS) {
            error = RegSetValueExW(key, value_name, 0, REG_SZ, (const BYTE *)command,
                                   (DWORD)((wcslen(command) + 1) * sizeof(WCHAR)));
            RegCloseKey(key);
        }
    } else {
        error = RegOpenKeyExW(HKEY_CURRENT_USER, CS_STARTUP_KEY, 0, KEY_SET_VALUE, &key);
        if (error == ERROR_FILE_NOT_FOUND)
            return 1;
        if (error == ERROR_SUCCESS) {
            error = RegDeleteValueW(key, value_name);
            RegCloseKey(key);
            if (error == ERROR_FILE_NOT_FOUND)
                error = ERROR_SUCCESS;
        }
    }
    SetLastError((DWORD)error);
    return error == ERROR_SUCCESS;
}
void cs_startup_toggle(void) {
    int status = cs_startup_status();
    if (status < 0 || !cs_startup_set_enabled(status != 1)) {
        DWORD error = GetLastError();
        if (error == ERROR_FILENAME_EXCED_RANGE)
            cs_notice("Could not change launch at login",
                      "Move Clipboard Sync to a shorter, permanent folder path and try again.");
        else {
            char message[160];
            snprintf(message, sizeof(message),
                     "Windows could not update the startup setting (error %lu).",
                     (unsigned long)error);
            cs_notice("Could not change launch at login", message);
        }
    }
}
