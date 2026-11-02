#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#elif !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif
#include "bridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

int main(void) {
    char base[2048];
#ifdef _WIN32
    char temp[MAX_PATH];
    assert(GetTempPathA(sizeof(temp), temp));
    assert(GetTempFileNameA(temp, "csl", 0, base));
    assert(DeleteFileA(base));
    assert(CreateDirectoryA(base, NULL));
    assert(SetEnvironmentVariableA("LOCALAPPDATA", base));
    const char *folder = "ClipboardSync";
#else
    strcpy(base, "/tmp/clipboard-sync-log-XXXXXX");
    assert(mkdtemp(base));
    assert(setenv("HOME", base, 1) == 0);
    const char *folder = ".clipboard-sync";
#endif
    assert(cs_storage_init());
    cs_log_init("test-version-1");
    unsigned char event[16], wire[12];
    memset(event, 0xab, sizeof(event));
    memset(wire, 0xcd, sizeof(wire));
    cs_log_event("clipboard_written", event, wire, "192.0.2.1", 1, 42, 7);
    char path[2300], previous[2300], directory[2200];
    snprintf(directory, sizeof(directory), "%s/%s", base, folder);
    snprintf(path, sizeof(path), "%s/sync.log", directory);
    snprintf(previous, sizeof(previous), "%s/sync.log.1", directory);
    FILE *f = fopen(path, "rb");
    assert(f);
    char line[1024];
    assert(fgets(line, sizeof(line), f));
    assert(line[4] == '-' && line[10] == 'T' && line[19] == '.' && line[23] == 'Z');
    assert(strstr(line, "stage=clipboard_written"));
    assert(strstr(line, "event=abababababababababababababababab"));
    assert(strstr(line, "wire=cdcdcdcdcdcdcdcdcdcdcdcd"));
    assert(strstr(line, "peer=192.0.2.1 kind=1 bytes=42 elapsed_ms=7"));
    assert(!fgets(line, sizeof(line), f));
    fclose(f);
    // Last 50 entries survive a same-version restart in chronological order.
    for (int i = 0; i < 120; ++i)
        cs_log_event("sent", NULL, wire, "192.0.2.1", 0, (size_t)i, 12);
    cs_log_init("test-version-1");
    f = fopen(path, "rb");
    assert(f);
    for (int i = 70; i < 120; ++i) {
        assert(fgets(line, sizeof(line), f));
        char expected[64];
        snprintf(expected, sizeof(expected), "bytes=%d elapsed_ms=12", i);
        assert(strstr(line, expected));
        assert(strstr(line, "event=-"));
        assert(strstr(line, "stage=sent"));
    }
    assert(!fgets(line, sizeof(line), f));
    fclose(f);
    // A version change clears the log and deletes backups from older releases.
    f = fopen(previous, "wb");
    assert(f);
    fputs("legacy backup\n", f);
    fclose(f);
    cs_log_init("test-version-2");
    f = fopen(path, "rb");
    assert(f && fgetc(f) == EOF);
    fclose(f);
    f = fopen(previous, "rb");
    assert(!f);
    cs_log_event("new_version", NULL, NULL, "local", 0, 0, 0);
    f = fopen(path, "rb");
    assert(f && fgets(line, sizeof(line), f));
    assert(strstr(line, "stage=new_version"));
    assert(!fgets(line, sizeof(line), f));
    fclose(f);
    // Removing or truncating the file must not resurrect the old in-memory entries.
    assert(remove(path) == 0);
    cs_log_event("after_delete", NULL, NULL, "local", 0, 0, 0);
    f = fopen(path, "rb");
    assert(f && fgets(line, sizeof(line), f));
    assert(strstr(line, "stage=after_delete"));
    assert(!fgets(line, sizeof(line), f));
    fclose(f);
    f = fopen(path, "wb");
    assert(f);
    fclose(f);
    cs_log_event("after_truncate", NULL, NULL, "local", 0, 0, 0);
    f = fopen(path, "rb");
    assert(f && fgets(line, sizeof(line), f));
    assert(strstr(line, "stage=after_truncate"));
    assert(!fgets(line, sizeof(line), f));
    fclose(f);
    remove(path);
    remove(previous);
    snprintf(path, sizeof(path), "%s/log-version", directory);
    remove(path);
#ifndef _WIN32
    snprintf(path, sizeof(path), "%s/instance.lock", directory);
    unlink(path);
    rmdir(directory);
    rmdir(base);
#else
    _rmdir(directory);
    _rmdir(base);
#endif
    puts("log timestamps, correlation metadata, 50-entry retention, version reset and external "
         "clearing passed");
    return 0;
}
