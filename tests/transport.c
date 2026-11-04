/* Real sockets: bounded polling and bidirectional clipboard traffic over a paired
   channel whose client has no listening socket (as with an inbound firewall). */
#include "bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <wchar.h>
#define pause_ms() Sleep(1)
typedef SOCKET raw_socket;
#define RAW_BAD INVALID_SOCKET
#define raw_close closesocket
#else
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#define pause_ms() usleep(1000)
typedef int raw_socket;
#define RAW_BAD (-1)
#define raw_close close
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
/* Encrypted prefix (42 bytes) alone, and with a 255-byte name and a full payload. */
#define MIN_PAYLOAD 42
#define MAX_PAYLOAD (CS_MAX + 42 + 255)
static unsigned char packet[CS_MAX + 512], received[CS_MAX + 512];
extern unsigned short cs_test_net_port(void);
extern void cs_test_set_port(unsigned short port);
extern int cs_test_outgoing_frames(const char *ip);
extern int cs_test_age_idle_peer(const char *ip, uint64_t age_ms);
extern size_t cs_test_unverified_bytes(void);
extern size_t cs_test_unverified_limit(void);
extern int cs_test_unverified_channels(void);
extern void cs_test_age_unverified(uint64_t age_ms);
static size_t make_frame(const char *magic, size_t payload, int stage) {
    memcpy(packet, magic, 8);
    packet[52] = (unsigned char)(payload >> 24);
    packet[53] = (unsigned char)(payload >> 16);
    packet[54] = (unsigned char)(payload >> 8);
    packet[55] = (unsigned char)payload;
    for (size_t i = 56; i < payload + 56; i++)
        packet[i] = (unsigned char)(i * 37);
    if (stage)
        packet[56] = (unsigned char)stage;
    return payload + 56;
}
static int wait_frame(void) {
    char ip[16];
    uint64_t until = cs_millis() + 6000;
    while (cs_millis() < until) {
        int got = cs_receive(received, sizeof(received), ip);
        if (got)
            return got;
        pause_ms();
    }
    return 0;
}
static int wait_pair(int stage) {
    int got = wait_frame();
    return got == (stage <= 2 ? 186 : 89) && !memcmp(received, "CLIPPR03", 8) &&
           received[56] == stage;
}
static int round_trip(size_t payload) {
    size_t size = make_frame("CLIPSY02", payload, 0);
    if (!cs_send("127.0.0.1", packet, size))
        return 0;
    return wait_frame() == (int)size && !memcmp(packet, received, size);
}
static int nonblocking_send(void) {
    size_t size = make_frame("CLIPSY02", MIN_PAYLOAD, 0);
    uint64_t before = cs_millis();
    int queued = cs_send("192.0.2.1", packet, size); // Reserved documentation address.
    for (int i = 0; i < 16; ++i)
        if (!cs_send_control("192.0.2.1", packet, size))
            return 0;
    // One real update plus one control probe, rather than an accumulating probe queue.
    if (cs_test_outgoing_frames("192.0.2.1") != 2)
        return 0;
    uint64_t elapsed = cs_millis() - before;
    cs_peer_forget("192.0.2.1");
    return queued && elapsed < 250;
}
static void drain(int polls) {
    char ip[16];
    for (int i = 0; i < polls; i++) {
        cs_receive(received, sizeof(received), ip);
        pause_ms();
    }
}
/* LAN clients that never authenticate: some claim maximum-size frames and trickle,
   others only hold a connection open. Authenticated and outgoing traffic must keep
   room in the shared queue, and the connections must be closed at their deadline. */
static int unverified_flood(void) {
    enum { CLIENTS = 24, HEADERS = 6 };
    raw_socket clients[CLIENTS];
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(cs_test_net_port());
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    make_frame("CLIPSY02", MAX_PAYLOAD, 0); // Each header claims a full-size frame.
    int ok = 1;
    for (int i = 0; i < CLIENTS; i++)
        clients[i] = RAW_BAD;
    for (int i = 0; i < CLIENTS; i++) {
        clients[i] = socket(AF_INET, SOCK_STREAM, 0);
        if (clients[i] == RAW_BAD ||
            connect(clients[i], (struct sockaddr *)&address, sizeof(address))) {
            ok = 0;
            break;
        }
        if (i < HEADERS)
            send(clients[i], (const char *)packet, 56 + 1000, MSG_NOSIGNAL);
        drain(5); // Accept before the listen backlog fills.
    }
    drain(100);
    size_t held = cs_test_unverified_bytes();
    int channels = cs_test_unverified_channels();
    if (ok && (held == 0 || held > cs_test_unverified_limit() || channels > 16)) {
        fprintf(stderr, "unverified connections held %zu bytes on %d channels\n", held, channels);
        ok = 0;
    }
    // Two maximum-size outgoing copies still fit in the shared queue.
    size_t n = make_frame("CLIPSY02", MAX_PAYLOAD, 0);
    if (ok && !(cs_send("192.0.2.1", packet, n) && cs_send("192.0.2.1", packet, n))) {
        fprintf(stderr, "outgoing copies were starved by unverified connections\n");
        ok = 0;
    }
    cs_peer_forget("192.0.2.1");
    cs_test_age_unverified(120000);
    drain(5);
    if (ok && (cs_test_unverified_bytes() || cs_test_unverified_channels())) {
        fprintf(stderr, "unverified connections outlived their deadline\n");
        ok = 0;
    }
    for (int i = 0; i < CLIENTS; i++)
        if (clients[i] != RAW_BAD)
            raw_close(clients[i]);
    cs_peer_forget("127.0.0.1");
    return ok;
}
static int pair_client(unsigned short port) {
    cs_test_set_port(port); // Deliberately no listener in this process.
    size_t n = make_frame("CLIPPR03", 130, 1);
    if (!cs_pair_send("127.0.0.1", packet, n) || !wait_pair(2))
        return 0;
    n = make_frame("CLIPPR03", 33, 3);
    if (!cs_pair_send("127.0.0.1", packet, n) || !wait_pair(4))
        return 0;
    cs_peer_authorized("127.0.0.1");
    cs_pair_close();
    if (!cs_peer_connected("127.0.0.1"))
        return 0;
    // Repeated copies in both directions must reuse the authenticated channel.
    for (int i = 0; i < 20; i++) {
        n = make_frame("CLIPSY02", (size_t)(MIN_PAYLOAD + i), 0);
        if (!cs_send("127.0.0.1", packet, n) || wait_frame() != (int)n ||
            memcmp(packet, received, n))
            return 0;
    }
    // A healthy connection idle for >10 seconds must send the next copy immediately.
    // Age only its idle clock, avoiding an actual ten-second sleep in every test run.
    if (!cs_test_age_idle_peer("127.0.0.1", 11000))
        return 0;
    uint64_t before = cs_millis();
    if (!round_trip(MIN_PAYLOAD) || cs_millis() - before >= 1000) {
        fprintf(stderr, "idle clipboard connection incurred a reconnect delay\n");
        return 0;
    }
    n = make_frame("CLIPSY02", MAX_PAYLOAD, 0);
    if (!cs_send("127.0.0.1", packet, n) || wait_frame() != (int)n || memcmp(packet, received, n))
        return 0;
    n = make_frame("CLIPSY02", MIN_PAYLOAD, 0);
    if (!cs_send("127.0.0.1", packet, n) || wait_frame() != (int)n)
        return 0;
    cs_net_close();
    return 1;
}
static int paired_traffic(void) {
    unsigned short port = cs_test_net_port();
#ifdef _WIN32
    WCHAR path[32768], command[33000];
    GetModuleFileNameW(NULL, path, 32768);
    swprintf(command, 33000, L"\"%ls\" --pair-client %u", path, port);
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION child;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child))
        return 0;
#else
    pid_t child = fork();
    if (child < 0)
        return 0;
    if (child == 0) {
        cs_net_close();
        _exit(pair_client(port) ? 0 : 1);
    }
#endif
    int ok = wait_pair(1);
    size_t n = make_frame("CLIPPR03", 130, 2);
    ok = ok && cs_pair_send("127.0.0.1", packet, n) && wait_pair(3);
    cs_peer_authorized("127.0.0.1");
    n = make_frame("CLIPPR03", 33, 4);
    ok = ok && cs_pair_send("127.0.0.1", packet, n);
    cs_pair_close(); // Authorization preserves the socket and queued final confirmation.
    for (int i = 0; ok && i < 23; i++) {
        int got = wait_frame();
        ok = got > 0 && !memcmp(received, "CLIPSY02", 8) && cs_peer_connected("127.0.0.1");
        if (ok)
            ok = cs_send("127.0.0.1", received, (size_t)got);
    }
    // Poll until the final response has left the queue and the client closes.
    uint64_t until = cs_millis() + 1000;
    while (cs_peer_connected("127.0.0.1") && cs_millis() < until) {
        char ip[16];
        cs_receive(received, sizeof(received), ip);
        pause_ms();
    }
#ifdef _WIN32
    WaitForSingleObject(child.hProcess, 10000);
    DWORD result = 1;
    GetExitCodeProcess(child.hProcess, &result);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    return ok && result == 0;
#else
    int status = 0;
    waitpid(child, &status, 0);
    return ok && WIFEXITED(status) && WEXITSTATUS(status) == 0;
#endif
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--pair-client"))
        return pair_client((unsigned short)atoi(argv[2])) ? 0 : 1;
    if (!cs_net_init()) {
        fprintf(stderr, "transport: cannot initialize\n");
        return 1;
    }
    int ok = nonblocking_send() && round_trip(MIN_PAYLOAD) && round_trip(MAX_PAYLOAD);
    cs_peer_forget("127.0.0.1");
    ok = ok && unverified_flood() && round_trip(MAX_PAYLOAD);
    cs_peer_forget("127.0.0.1");
    ok = ok && paired_traffic();
    cs_net_close();
    if (!ok) {
        fprintf(stderr, "transport: paired clipboard transfer failed: %s\n", cs_net_error());
        return 1;
    }
    puts("transport: non-blocking send, unauthenticated flood limits, pairing, 20 bidirectional "
         "copies and 5 MiB transfers without a reverse listener passed");
    return 0;
}
