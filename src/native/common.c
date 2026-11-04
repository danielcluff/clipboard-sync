#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#elif !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif
#include "bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <direct.h>
#include <sys/stat.h>
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#ifndef S_ISREG
#define S_ISREG(mode) (((mode) & _S_IFMT) == _S_IFREG)
#endif
typedef SOCKET sock;
#define BAD INVALID_SOCKET
#define close_socket closesocket
static WCHAR *wide_path(const char *text) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!n)
        return NULL;
    WCHAR *out = malloc((size_t)n * sizeof(WCHAR));
    if (out)
        MultiByteToWideChar(CP_UTF8, 0, text, -1, out, n);
    return out;
}
static int mkdir_private(const char *path) {
    WCHAR *w = wide_path(path);
    if (!w)
        return -1;
    int result = _wmkdir(w);
    free(w);
    return result;
}
static FILE *file_open(const char *path, const char *mode) {
    WCHAR *w = wide_path(path), *m = wide_path(mode);
    FILE *f = w && m ? _wfopen(w, m) : NULL;
    free(w);
    free(m);
    return f;
}
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
typedef int sock;
#define BAD (-1)
#define close_socket close
#define mkdir_private(p) mkdir(p, 0700)
#define file_open fopen
#endif
static char root[2048];
static sock tcp = BAD, udp = BAD;
#ifndef CS_PORT
#define CS_PORT 45832
#endif
static unsigned short service_port = CS_PORT;
#ifdef CS_TESTING
unsigned short cs_test_net_port(void) { return service_port; }
void cs_test_set_port(unsigned short port) {
    service_port = port;
#ifdef _WIN32
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
#endif
}
#endif
static char net_error[320] = "No connection error recorded.";
static int lock_fd = -1;
int cs_storage_init(void) {
#ifdef _WIN32
    WCHAR local[2048];
    char utf8_base[8192];
    DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", local, 2048);
    if (size == 0 || size >= 2048 ||
        !WideCharToMultiByte(CP_UTF8, 0, local, -1, utf8_base, sizeof(utf8_base), NULL, NULL))
        return 0;
    const char *base = utf8_base;
#else
    const char *base = getenv("HOME");
#endif
    if (!base)
        return 0;
    if (snprintf(root, sizeof(root), "%s/%s", base,
#ifdef _WIN32
                 "ClipboardSync"
#else
                 ".clipboard-sync"
#endif
                 ) >= (int)sizeof(root))
        return 0;
    mkdir_private(root);
#ifndef _WIN32
    struct stat st;
    if (lstat(root, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid())
        return 0;
    chmod(root, 0700);
    char lock_path[2200];
    snprintf(lock_path, sizeof(lock_path), "%s/instance.lock", root);
    lock_fd = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    struct flock lk = {0};
    lk.l_type = F_WRLCK;
    lk.l_whence = SEEK_SET;
    if (lock_fd < 0 || fcntl(lock_fd, F_SETLK, &lk) < 0)
        return 0;
#else
    HANDLE mutex = CreateMutexA(NULL, FALSE, "Local\\ClipboardSyncSingleInstance");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS)
        return 0;
#endif
    return 1;
}
/* Retain exactly the newest 50 complete entries. Snapshots are atomically replaced,
   so readers see complete files and a failed write preserves the previous snapshot. */
#define LOG_ENTRIES 50
#define LOG_LINE 768
static char log_lines[LOG_ENTRIES][LOG_LINE];
static size_t log_count, log_next;
static int log_ready;
static int log_was_cleared(void) {
    char path[2200];
    snprintf(path, sizeof(path), "%s/sync.log", root);
#ifdef _WIN32
    WCHAR *w = wide_path(path);
    WIN32_FILE_ATTRIBUTE_DATA info;
    int ok = w && GetFileAttributesExW(w, GetFileExInfoStandard, &info);
    DWORD error = GetLastError();
    free(w);
    return ok ? info.nFileSizeHigh == 0 && info.nFileSizeLow == 0 : error == ERROR_FILE_NOT_FOUND;
#else
    struct stat info;
    int ok = lstat(path, &info) == 0;
    return ok ? info.st_size == 0 : errno == ENOENT;
#endif
}
static FILE *log_write_file(const char *path) {
#ifdef _WIN32
    return file_open(path, "wb");
#else
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    FILE *f = fd < 0 ? NULL : fdopen(fd, "wb");
    if (fd >= 0 && !f)
        close(fd);
    return f;
#endif
}
static int log_snapshot(void) {
    char path[2200], tmp[2200];
    snprintf(path, sizeof(path), "%s/sync.log", root);
    snprintf(tmp, sizeof(tmp), "%s/sync.log.tmp", root);
    FILE *f = log_write_file(tmp);
    if (!f)
        return 0;
    int ok = 1;
    size_t first = log_count == LOG_ENTRIES ? log_next : 0;
    for (size_t i = 0; i < log_count; ++i)
        if (fputs(log_lines[(first + i) % LOG_ENTRIES], f) == EOF)
            ok = 0;
    if (fclose(f))
        ok = 0;
    if (!ok)
        return 0;
#ifdef _WIN32
    WCHAR *from = wide_path(tmp), *to = wide_path(path);
    int moved = from && to && MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING);
    free(from);
    free(to);
    return moved != 0;
#else
    return rename(tmp, path) == 0;
#endif
}
void cs_log_init(const char *version) {
    if (!root[0])
        return;
    log_count = log_next = 0;
    log_ready = 0;
    char path[2200], previous_version[64] = {0};
    snprintf(path, sizeof(path), "%s/log-version", root);
    FILE *f = file_open(path, "rb");
    if (f) {
        size_t n = fread(previous_version, 1, sizeof(previous_version) - 1, f);
        previous_version[n] = 0;
        fclose(f);
    }
    if (!strcmp(previous_version, version)) {
        snprintf(path, sizeof(path), "%s/sync.log", root);
        f = file_open(path, "rb");
        if (f) {
            char line[LOG_LINE];
            while (fgets(line, sizeof(line), f)) {
                if (!strchr(line, '\n')) {
                    int ch;
                    while ((ch = fgetc(f)) != EOF && ch != '\n') {
                    }
                    continue;
                }
                strcpy(log_lines[log_next], line);
                log_next = (log_next + 1) % LOG_ENTRIES;
                if (log_count < LOG_ENTRIES)
                    log_count++;
            }
            fclose(f);
        }
    }
    // Keep collecting in memory if a viewer temporarily blocks file replacement.
    log_ready = 1;
    // Also prune on same-version restarts, including any previously oversized log.
    if (!log_snapshot())
        return;
    snprintf(path, sizeof(path), "%s/sync.log.1", root);
#ifdef _WIN32
    WCHAR *old = wide_path(path);
    if (old)
        DeleteFileW(old);
    free(old);
#else
    unlink(path);
#endif
    snprintf(path, sizeof(path), "%s/log-version", root);
    f = log_write_file(path);
    if (f) {
        fputs(version, f);
        fclose(f);
    }
    log_ready = 1;
}
void cs_log_event(const char *stage, const unsigned char *event, const unsigned char *wire,
                  const char *peer, int kind, size_t bytes, uint64_t elapsed_ms) {
    if (!log_ready)
        return;
    // Deleting or emptying the log is an explicit reset, including the memory ring.
    if (log_count && log_was_cleared())
        log_count = log_next = 0;
    time_t seconds;
    unsigned millis;
#ifdef _WIN32
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER ticks;
    ticks.LowPart = ft.dwLowDateTime;
    ticks.HighPart = ft.dwHighDateTime;
    uint64_t epoch_ms = ticks.QuadPart / 10000 - 11644473600000ULL;
    seconds = (time_t)(epoch_ms / 1000);
    millis = (unsigned)(epoch_ms % 1000);
    struct tm utc;
    gmtime_s(&utc, &seconds);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    seconds = ts.tv_sec;
    millis = (unsigned)(ts.tv_nsec / 1000000);
    struct tm utc;
    gmtime_r(&seconds, &utc);
#endif
    char timestamp[32], event_hex[33] = "-", wire_hex[25] = "-";
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S", &utc);
    if (event)
        for (size_t i = 0; i < 16; ++i)
            snprintf(event_hex + 2 * i, 3, "%02x", event[i]);
    if (wire)
        for (size_t i = 0; i < 12; ++i)
            snprintf(wire_hex + 2 * i, 3, "%02x", wire[i]);
    snprintf(log_lines[log_next], LOG_LINE,
             "%s.%03uZ mono_ms=%llu stage=%s event=%s wire=%s peer=%s kind=%d bytes=%zu "
             "elapsed_ms=%llu\n",
             timestamp, millis, (unsigned long long)cs_millis(), stage, event_hex, wire_hex, peer,
             kind, bytes, (unsigned long long)elapsed_ms);
    log_next = (log_next + 1) % LOG_ENTRIES;
    if (log_count < LOG_ENTRIES)
        log_count++;
    log_snapshot();
}
int cs_load(void *data, size_t cap) {
    char path[2200];
    snprintf(path, sizeof(path), "%s/devices.bin", root);
    FILE *f = file_open(path, "rb");
    if (!f)
        return 0;
    size_t n = fread(data, 1, cap, f);
    int extra = fgetc(f);
    fclose(f);
    return extra == EOF ? (int)n : 0;
}
int cs_save(const void *data, size_t len) {
    char path[2200], tmp[2200];
    snprintf(path, sizeof(path), "%s/devices.bin", root);
    snprintf(tmp, sizeof(tmp), "%s/devices.tmp", root);
#ifndef _WIN32
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return 0;
    FILE *f = fdopen(fd, "wb");
    if (!f) {
        close(fd);
        return 0;
    }
#else
    FILE *f = file_open(tmp, "wb");
    if (!f)
        return 0;
#endif
    int ok = fwrite(data, 1, len, f) == len;
    if (fflush(f))
        ok = 0;
#ifndef _WIN32
    if (fsync(fileno(f)))
        ok = 0;
#endif
    if (fclose(f))
        ok = 0;
    if (!ok)
        return 0;
#ifdef _WIN32
    WCHAR *from = wide_path(tmp), *to = wide_path(path);
    int moved =
        from && to && MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    free(from);
    free(to);
    return moved;
#else
    return rename(tmp, path) == 0;
#endif
}
int cs_read_file(const char *path, cs_clip *out) {
    memset(out, 0, sizeof(*out));
    FILE *f = file_open(path, "rb");
    if (!f)
        return 0;
    struct stat st;
    if (fstat(fileno(f), &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > CS_MAX) {
        fclose(f);
        return 0;
    }
    out->len = (size_t)st.st_size;
    out->data = malloc(out->len + 1);
    if (!out->data) {
        fclose(f);
        return 0;
    }
    if (fread(out->data, 1, out->len, f) != out->len) {
        fclose(f);
        cs_clip_free(out);
        return 0;
    }
    fclose(f);
    out->kind = 2;
    const char *name = path;
    for (const char *p = path; *p; p++)
        if (*p == '/' || *p == '\\')
            name = p + 1;
    if (strlen(name) > 255) {
        cs_clip_free(out);
        return 0;
    }
    strcpy(out->name, name);
    return 1;
}
const char *cs_save_file(const unsigned char *data, size_t len, const char *name) {
    // Each history restore gets its own directory; never overwrite a previously pasted file.
    static char path[2600];
    char dir[2400];
    unsigned char random[8];
    if (len > CS_MAX || !cs_random(random, sizeof(random)))
        return NULL;
    snprintf(dir, sizeof(dir), "%s/transfers", root);
    mkdir_private(dir);
    size_t used = strlen(dir);
    snprintf(dir + used, sizeof(dir) - used, "/%02x%02x%02x%02x%02x%02x%02x%02x", random[0],
             random[1], random[2], random[3], random[4], random[5], random[6], random[7]);
    if (mkdir_private(dir))
        return NULL;
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = file_open(path, "wb");
    if (!f)
        return NULL;
    int ok = fwrite(data, 1, len, f) == len;
    if (fclose(f))
        ok = 0;
    return ok ? path : NULL;
}
void cs_clip_free(cs_clip *clip) {
    free(clip->data);
    memset(clip, 0, sizeof(*clip));
}
int cs_random(void *data, size_t len) {
#ifdef _WIN32
    // SystemFunction036 is the system's cryptographic RNG (RtlGenRandom).
    typedef BOOLEAN(WINAPI * rng_fn)(PVOID, ULONG);
    HMODULE lib = LoadLibraryA("advapi32.dll");
    if (!lib)
        return 0;
    rng_fn rng = (rng_fn)GetProcAddress(lib, "SystemFunction036");
    int ok = rng && rng(data, (ULONG)len);
    FreeLibrary(lib);
    return ok;
#else
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f)
        return 0;
    int ok = fread(data, 1, len, f) == len;
    fclose(f);
    return ok;
#endif
}
uint64_t cs_millis(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
#endif
}
void cs_hostname(char *out, size_t cap) {
    if (gethostname(out, (int)cap))
        strncpy(out, "Device", cap);
    out[cap - 1] = 0;
}
/* All transport state belongs to the main thread. Every socket is non-blocking;
   a poll has bounded I/O work and never waits for another computer. */
#define CHANNEL_COUNT 32
#define NETWORK_LIMIT (32 * 1024 * 1024)
/* 56-byte cleartext header, 42-byte encrypted prefix, file name, and payload. */
#define FRAME_LIMIT (CS_MAX + 56 + 42 + 255)
#define IO_QUANTUM (256 * 1024)
/* Connections that have not yet delivered an authenticated frame share a small part of
   the queue and slot table, and must finish within a deadline, so a LAN client that
   only sends headers cannot starve authenticated peers. */
#define UNVERIFIED_LIMIT (2 * (FRAME_LIMIT + sizeof(frame)))
#define UNVERIFIED_INCOMING 16
#define UNVERIFIED_GRACE_MS 15000
#define UNVERIFIED_BYTES_PER_MS 128
typedef struct frame {
    struct frame *next;
    size_t size, offset;
    uint64_t created;
    int channel, quiet, unverified;
    unsigned generation;
    char ip[16];
    unsigned char bytes[];
} frame;
typedef struct {
    int used, connecting, authenticated, closing, incoming;
    sock socket;
    char ip[16];
    unsigned generation;
    uint64_t progress, retry_at, opened;
    unsigned char header[56];
    size_t header_read;
    frame *input, *out_head, *out_tail;
} channel;
static channel channels[CHANNEL_COUNT];
#ifdef CS_TESTING
int cs_test_outgoing_frames(const char *ip) {
    int count = 0;
    for (int i = 0; i < CHANNEL_COUNT; ++i)
        if (channels[i].used && !strcmp(channels[i].ip, ip))
            for (frame *f = channels[i].out_head; f; f = f->next)
                count++;
    return count;
}
int cs_test_age_idle_peer(const char *ip, uint64_t age_ms) {
    int aged = 0;
    for (int i = 0; i < CHANNEL_COUNT; ++i) {
        channel *c = &channels[i];
        if (c->used && c->authenticated && !strcmp(c->ip, ip) && !c->out_head && !c->header_read &&
            !c->input) {
            c->progress = cs_millis() - age_ms;
            aged++;
        }
    }
    return aged;
}
#endif
static frame *incoming_head, *incoming_tail;
static size_t network_bytes, unverified_bytes;
static int pairing_channel = -1, delivered_channel = -1;
static unsigned delivered_generation;
static unsigned next_generation = 1;
const char *cs_net_error(void) { return net_error; }
static int socket_error(void) {
#ifdef _WIN32
    return WSAGetLastError();
#else
    return errno;
#endif
}
static int would_block(int error) {
#ifdef _WIN32
    return error == WSAEWOULDBLOCK || error == WSAEINPROGRESS;
#else
    return error == EAGAIN || error == EWOULDBLOCK || error == EINPROGRESS || error == EINTR;
#endif
}
static void record_error(const char *operation, int error) {
#ifdef _WIN32
    char description[220] = {0};
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, (DWORD)error,
                   0, description, sizeof(description), NULL);
#else
    const char *description = strerror(error);
#endif
    snprintf(net_error, sizeof(net_error), "%s: %s (%d)", operation, description, error);
}
static int nonblocking(sock s) {
#ifdef _WIN32
    u_long mode = 1;
    return ioctlsocket(s, FIONBIO, &mode) == 0;
#else
    int flags = fcntl(s, F_GETFL, 0);
    return flags >= 0 && fcntl(s, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}
static void configure_socket(sock s) {
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char *)&yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
}
static int ready(sock s, int writing) {
    if (s == BAD)
        return 0;
    fd_set set, failed;
    FD_ZERO(&set);
    FD_SET(s, &set);
    FD_ZERO(&failed);
    FD_SET(s, &failed);
    struct timeval zero = {0, 0};
    return select((int)s + 1, writing ? NULL : &set, writing ? &set : NULL,
                  writing ? &failed : NULL, &zero) > 0;
}
static frame *allocate_frame(size_t size) {
    if (size > FRAME_LIMIT || network_bytes + sizeof(frame) + size > NETWORK_LIMIT) {
        snprintf(net_error, sizeof(net_error), "Network queue is full.");
        return NULL;
    }
    frame *f = malloc(sizeof(frame) + size);
    if (!f)
        return NULL;
    memset(f, 0, sizeof(*f));
    f->size = size;
    f->created = cs_millis();
    network_bytes += sizeof(frame) + size;
    return f;
}
static void release_frame(frame *f) {
    if (!f)
        return;
    network_bytes -= sizeof(frame) + f->size;
    if (f->unverified)
        unverified_bytes -= sizeof(frame) + f->size;
    free(f);
}
static frame *allocate_input(const channel *c, size_t size) {
    if (c->authenticated)
        return allocate_frame(size);
    if (unverified_bytes + sizeof(frame) + size > UNVERIFIED_LIMIT) {
        snprintf(net_error, sizeof(net_error), "Too much unauthenticated network data.");
        return NULL;
    }
    frame *f = allocate_frame(size);
    if (f) {
        f->unverified = 1;
        unverified_bytes += sizeof(frame) + size;
    }
    return f;
}
static int unverified_incoming(void) {
    int count = 0;
    for (int i = 0; i < CHANNEL_COUNT; i++)
        if (channels[i].used && channels[i].incoming && !channels[i].authenticated)
            count++;
    return count;
}
/* Time allowed before an unauthenticated inbound connection must authenticate. Large
   first frames get extra time proportional to their size for slow links. */
static uint64_t unverified_deadline(const channel *c) {
    return UNVERIFIED_GRACE_MS + (c->input ? c->input->size / UNVERIFIED_BYTES_PER_MS : 0);
}
#ifdef CS_TESTING
size_t cs_test_unverified_bytes(void) { return unverified_bytes; }
size_t cs_test_unverified_limit(void) { return UNVERIFIED_LIMIT; }
int cs_test_unverified_channels(void) { return unverified_incoming(); }
void cs_test_age_unverified(uint64_t age_ms) {
    for (int i = 0; i < CHANNEL_COUNT; i++)
        if (channels[i].used && channels[i].incoming && !channels[i].authenticated)
            channels[i].opened = cs_millis() - age_ms;
}
#endif
static void close_channel(int i, int retry) {
    channel *c = &channels[i];
    if (!c->used)
        return;
    if (c->socket != BAD)
        close_socket(c->socket);
    c->socket = BAD;
    release_frame(c->input);
    c->input = NULL;
    c->header_read = 0;
    c->authenticated = c->connecting = 0;
    int pairing = pairing_channel == i;
    if (pairing)
        pairing_channel = -1;
    if (retry && !pairing && c->out_head && cs_millis() - c->out_head->created < 30000) {
        for (frame *f = c->out_head; f; f = f->next)
            f->offset = 0;
        for (frame *f = c->out_head; f; f = f->next) {
            if (!f->quiet) {
                cs_log_event("connection_retry_scheduled", NULL,
                             f->size >= 56 && !memcmp(f->bytes, "CLIPSY02", 8) ? f->bytes + 24
                                                                               : NULL,
                             c->ip, 0, f->size, cs_millis() - f->created);
                break;
            }
        }
        c->retry_at = cs_millis() + 3000;
        return;
    }
    while (c->out_head) {
        frame *f = c->out_head;
        c->out_head = f->next;
        release_frame(f);
    }
    c->out_tail = NULL;
    c->used = 0;
}
static int new_channel(const char *ip, sock s) {
    for (int i = 0; i < CHANNEL_COUNT; i++)
        if (!channels[i].used) {
            channel *c = &channels[i];
            memset(c, 0, sizeof(*c));
            c->used = 1;
            c->socket = s;
            c->generation = next_generation++;
            c->progress = c->opened = cs_millis();
            snprintf(c->ip, sizeof(c->ip), "%s", ip);
            return i;
        }
    snprintf(net_error, sizeof(net_error), "Too many open network connections.");
    return -1;
}
static int connect_channel(int i) {
    channel *c = &channels[i];
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(service_port);
    if (inet_pton(AF_INET, c->ip, &address.sin_addr) != 1) {
        snprintf(net_error, sizeof(net_error), "Invalid IPv4 address: %s", c->ip);
        return 0;
    }
    sock s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == BAD || !nonblocking(s)) {
        record_error("Socket", socket_error());
        if (s != BAD)
            close_socket(s);
        return 0;
    }
    configure_socket(s);
    int result = connect(s, (struct sockaddr *)&address, sizeof(address));
    if (result && !would_block(socket_error())) {
        record_error("Connect", socket_error());
        close_socket(s);
        return 0;
    }
    c->socket = s;
    c->incoming = 0;
    c->connecting = result != 0;
    c->progress = cs_millis();
    c->retry_at = 0;
    return 1;
}
static int existing_channel(const char *ip) {
    int fallback = -1;
    for (int i = 0; i < CHANNEL_COUNT; i++) {
        channel *c = &channels[i];
        if (!c->used || strcmp(c->ip, ip))
            continue;
        if (c->authenticated && c->socket != BAD && !c->connecting)
            return i;
        if (c->socket != BAD && !c->connecting)
            fallback = i;
        else if (fallback < 0)
            fallback = i;
    }
    return fallback;
}
static int enqueue(int i, const void *data, size_t len, int quiet) {
    frame *f = allocate_frame(len);
    if (!f)
        return 0;
    memcpy(f->bytes, data, len);
    f->quiet = quiet;
    channel *c = &channels[i];
    // Healthy authenticated sockets may idle indefinitely. A new outgoing copy starts
    // a fresh I/O timeout; idle time is not time spent trying to send this frame.
    if (!c->out_head && c->authenticated && !c->header_read && !c->input)
        c->progress = cs_millis();
    if (c->out_tail)
        c->out_tail->next = f;
    else
        c->out_head = f;
    c->out_tail = f;
    return 1;
}
static void adopt_queue(int target) {
    channel *to = &channels[target];
    for (int i = 0; i < CHANNEL_COUNT; i++) {
        channel *from = &channels[i];
        if (i == target || !from->used || i == pairing_channel || strcmp(from->ip, to->ip))
            continue;
        if (from->socket != BAD && !from->connecting)
            continue;
        if (from->out_head) {
            for (frame *f = from->out_head; f; f = f->next)
                f->offset = 0;
            if (to->out_tail)
                to->out_tail->next = from->out_head;
            else
                to->out_head = from->out_head;
            to->out_tail = from->out_tail;
            from->out_head = from->out_tail = NULL;
        }
        close_channel(i, 0);
    }
}
static int valid_length(const unsigned char *header, size_t *size) {
    uint32_t len = ((uint32_t)header[52] << 24) | ((uint32_t)header[53] << 16) |
                   ((uint32_t)header[54] << 8) | header[55];
    int clip = !memcmp(header, "CLIPSY02", 8) && len >= 42 && len <= FRAME_LIMIT - 56;
    int pair = !memcmp(header, "CLIPPR03", 8) && len >= 1 && len <= 130;
    *size = (size_t)len + 56;
    return clip || pair;
}
static void flush_channel(int i) {
    channel *c = &channels[i];
    size_t budget = IO_QUANTUM;
    while (c->out_head && budget) {
        frame *f = c->out_head;
        size_t count = f->size - f->offset;
        if (count > budget)
            count = budget;
        int flags = 0;
#ifdef MSG_NOSIGNAL
        flags = MSG_NOSIGNAL;
#endif
        int n = (int)send(c->socket, (const char *)f->bytes + f->offset, (int)count, flags);
        if (n < 0 && would_block(socket_error()))
            return;
        if (n <= 0) {
            record_error("Send", socket_error());
            close_channel(i, 1);
            return;
        }
        f->offset += (size_t)n;
        budget -= (size_t)n;
        c->progress = cs_millis();
        if (f->offset == f->size) {
            if (!f->quiet && f->size >= 56 && !memcmp(f->bytes, "CLIPSY02", 8))
                cs_log_event("sent", NULL, f->bytes + 24, c->ip, 0, f->size,
                             cs_millis() - f->created);
            c->out_head = f->next;
            if (!c->out_head)
                c->out_tail = NULL;
            release_frame(f);
        }
    }
}
static void read_channel(int i) {
    channel *c = &channels[i];
    size_t budget = IO_QUANTUM;
    while (budget) {
        unsigned char *dest;
        size_t count;
        if (!c->input) {
            dest = c->header + c->header_read;
            count = 56 - c->header_read;
        } else {
            dest = c->input->bytes + c->input->offset;
            count = c->input->size - c->input->offset;
        }
        if (count > budget)
            count = budget;
        int n = (int)recv(c->socket, (char *)dest, (int)count, 0);
        if (n < 0 && would_block(socket_error()))
            return;
        if (n <= 0) {
            if (n < 0)
                record_error("Receive", socket_error());
            else
                snprintf(net_error, sizeof(net_error), "The other device closed the connection.");
            close_channel(i, 1);
            return;
        }
        budget -= (size_t)n;
        c->progress = cs_millis();
        if (!c->input) {
            c->header_read += (size_t)n;
            if (c->header_read == 56) {
                size_t size;
                if (!valid_length(c->header, &size) || !(c->input = allocate_input(c, size))) {
                    close_channel(i, 0);
                    return;
                }
                memcpy(c->input->bytes, c->header, 56);
                c->input->offset = 56;
            }
        } else {
            c->input->offset += (size_t)n;
            if (c->input->offset == c->input->size) {
                frame *f = c->input;
                if (!memcmp(f->bytes, "CLIPSY02", 8))
                    cs_log_event("received", NULL, f->bytes + 24, c->ip, 0, f->size, 0);
                c->input = NULL;
                c->header_read = 0;
                if (!memcmp(f->bytes, "CLIPPR03", 8)) {
                    if (pairing_channel < 0 && f->size == 186 && f->bytes[56] == 1)
                        pairing_channel = i;
                    if (pairing_channel != i) {
                        release_frame(f);
                        close_channel(i, 0);
                        return;
                    }
                }
                f->channel = i;
                f->generation = c->generation;
                strcpy(f->ip, c->ip);
                if (incoming_tail)
                    incoming_tail->next = f;
                else
                    incoming_head = f;
                incoming_tail = f;
                return;
            }
        }
    }
}
static void network_poll(void) {
    for (int count = 0; count < 4 && ready(tcp, 0); count++) {
        struct sockaddr_in from;
#ifdef _WIN32
        int len = sizeof(from);
#else
        socklen_t len = sizeof(from);
#endif
        sock s = accept(tcp, (struct sockaddr *)&from, &len);
        if (s == BAD)
            break;
        if (!nonblocking(s)) {
            close_socket(s);
            continue;
        }
        configure_socket(s);
        if (unverified_incoming() >= UNVERIFIED_INCOMING) {
            snprintf(net_error, sizeof(net_error), "Too many unauthenticated connections.");
            close_socket(s);
            continue;
        }
        char ip[16];
        inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
        int i = new_channel(ip, s);
        if (i < 0)
            close_socket(s);
        else
            channels[i].incoming = 1;
    }
    uint64_t now = cs_millis();
    for (int i = 0; i < CHANNEL_COUNT; i++) {
        channel *c = &channels[i];
        if (!c->used)
            continue;
        if (c->socket == BAD) {
            if (now < c->retry_at)
                continue;
            if (!connect_channel(i)) {
                close_channel(i, 1);
                continue;
            }
        }
        if (c->connecting) {
            if (!ready(c->socket, 1)) {
                if (now - c->progress > 2000) {
                    snprintf(net_error, sizeof(net_error),
                             "TCP connection timed out (port 45832).");
                    close_channel(i, 1);
                }
                continue;
            }
            int error = 0;
#ifdef _WIN32
            int size = sizeof(error);
#else
            socklen_t size = sizeof(error);
#endif
            if (getsockopt(c->socket, SOL_SOCKET, SO_ERROR, (char *)&error, &size))
                error = socket_error();
            if (error) {
                record_error("Connect", error);
                close_channel(i, 1);
                continue;
            }
            c->connecting = 0;
            c->progress = now;
        }
        if (c->incoming && !c->authenticated && now - c->opened > unverified_deadline(c)) {
            snprintf(net_error, sizeof(net_error),
                     "An unauthenticated connection did not finish in time.");
            close_channel(i, 0);
            continue;
        }
        if ((c->out_head || c->header_read || c->input || !c->authenticated) &&
            now - c->progress > 10000) {
            snprintf(net_error, sizeof(net_error), "The other device stopped responding.");
            close_channel(i, 1);
            continue;
        }
        flush_channel(i);
        if (c->used && c->closing && !c->out_head) {
            close_channel(i, 0);
            continue;
        }
        if (c->used && c->socket != BAD && !c->connecting)
            read_channel(i);
    }
}
int cs_net_init(void) {
#ifdef _WIN32
    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w))
        return 0;
#endif
    tcp = socket(AF_INET, SOCK_STREAM, 0);
    udp = socket(AF_INET, SOCK_DGRAM, 0);
    if (tcp == BAD || udp == BAD || !nonblocking(tcp) || !nonblocking(udp))
        return 0;
    int yes = 1;
    setsockopt(tcp, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(yes));
    setsockopt(udp, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(service_port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(tcp, (struct sockaddr *)&address, sizeof(address)) || listen(tcp, 16))
        return 0;
#ifdef _WIN32
    int len = sizeof(address);
#else
    socklen_t len = sizeof(address);
#endif
    if (getsockname(tcp, (struct sockaddr *)&address, &len))
        return 0;
    service_port = ntohs(address.sin_port);
    return bind(udp, (struct sockaddr *)&address, sizeof(address)) == 0;
}
void cs_announce(const void *data, size_t len) {
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(service_port);
    a.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(udp, data, (int)len, 0, (struct sockaddr *)&a, sizeof(a));
}
int cs_discover(void *out, size_t cap, char *ip) {
    struct sockaddr_in from;
#ifdef _WIN32
    int len = sizeof(from);
#else
    socklen_t len = sizeof(from);
#endif
    int got = (int)recvfrom(udp, out, (int)cap, 0, (struct sockaddr *)&from, &len);
    if (got > 0)
        inet_ntop(AF_INET, &from.sin_addr, ip, 16);
    return got > 0 ? got : 0;
}
int cs_receive(void *out, size_t cap, char *ip) {
    network_poll();
    if (!incoming_head)
        return 0;
    frame *f = incoming_head;
    incoming_head = f->next;
    if (!incoming_head)
        incoming_tail = NULL;
    delivered_channel = f->channel;
    delivered_generation = f->generation;
    size_t size = f->size;
    if (size > cap) {
        release_frame(f);
        return 0;
    }
    memcpy(out, f->bytes, size);
    strcpy(ip, f->ip);
    release_frame(f);
    return (int)size;
}
static int send_frame(const char *ip, const void *data, size_t len, int quiet) {
    size_t size;
    if (len < 56 || !valid_length(data, &size) || size != len)
        return 0;
    int i = existing_channel(ip);
    if (i < 0) {
        i = new_channel(ip, BAD);
        if (i < 0)
            return 0;
        if (!connect_channel(i)) {
            close_channel(i, 0);
            return 0;
        }
    }
    if (quiet) {
        // Keep at most one unsent control frame per connection while it reconnects.
        for (frame *f = channels[i].out_head; f; f = f->next)
            if (f->quiet)
                return 1;
    }
    return enqueue(i, data, len, quiet);
}
int cs_send(const char *ip, const void *data, size_t len) { return send_frame(ip, data, len, 0); }
int cs_send_control(const char *ip, const void *data, size_t len) {
    return send_frame(ip, data, len, 1);
}
int cs_pair_send(const char *ip, const void *data, size_t len) {
    const unsigned char *p = data;
    if (len < 57 || len > 186 || memcmp(p, "CLIPPR03", 8))
        return 0;
    if (pairing_channel < 0) {
        if (p[56] != 1)
            return 0;
        int i = new_channel(ip, BAD);
        if (i < 0)
            return 0;
        pairing_channel = i;
        if (!connect_channel(i)) {
            close_channel(i, 0);
            return 0;
        }
    }
    channel *c = &channels[pairing_channel];
    return !strcmp(c->ip, ip) && enqueue(pairing_channel, data, len, 1);
}
void cs_peer_authorized(const char *ip) {
    if (delivered_channel < 0)
        return;
    channel *c = &channels[delivered_channel];
    if (c->used && c->generation == delivered_generation && !strcmp(c->ip, ip)) {
        c->authenticated = 1;
        adopt_queue(delivered_channel);
    }
}
int cs_peer_connected(const char *ip) {
    for (int i = 0; i < CHANNEL_COUNT; i++) {
        channel *c = &channels[i];
        if (c->used && c->authenticated && c->socket != BAD && !c->connecting && !strcmp(c->ip, ip))
            return 1;
    }
    return 0;
}
void cs_peer_forget(const char *ip) {
    for (int i = 0; i < CHANNEL_COUNT; i++)
        if (channels[i].used && !strcmp(channels[i].ip, ip))
            close_channel(i, 0);
}
int cs_pair_status(void) {
    return pairing_channel < 0 ? 0 : (channels[pairing_channel].connecting ? 1 : 2);
}
void cs_pair_close(void) {
    int i = pairing_channel;
    pairing_channel = -1;
    if (i >= 0 && !channels[i].authenticated) {
        channel *c = &channels[i];
        if (c->out_head && c->out_head->size >= 57 && c->out_head->bytes[56] == 5 && !c->connecting)
            c->closing = 1;
        else
            close_channel(i, 0);
    }
}
void cs_net_close(void) {
    pairing_channel = -1;
    for (int i = 0; i < CHANNEL_COUNT; i++)
        close_channel(i, 0);
    while (incoming_head) {
        frame *f = incoming_head;
        incoming_head = f->next;
        release_frame(f);
    }
    incoming_tail = NULL;
    delivered_channel = -1;
    if (tcp != BAD)
        close_socket(tcp);
    if (udp != BAD)
        close_socket(udp);
    tcp = udp = BAD;
}
