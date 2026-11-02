#include "bridge.h"
#include <stdlib.h>
#include <string.h>
static unsigned char queued[CS_MAX + 512];
static size_t queued_len;
static char queued_ip[16];
static unsigned char sent[CS_MAX + 512];
static size_t sent_len;
static int writes, sends, saves;
static char log_stages[64][40];
static unsigned char log_events[64][16];
static int log_count;
static int pairing_visible, notices;
static char *local_text;
static uint64_t now = 1000;
void cs_test_reset(void) {
    free(local_text);
    local_text = NULL;
    queued_len = sent_len = 0;
    writes = sends = saves = 0;
    log_count = 0;
    pairing_visible = notices = 0;
    now = 1000;
}
void cs_test_queue(const void *data, size_t len, const char *ip) {
    memcpy(queued, data, len);
    queued_len = len;
    strncpy(queued_ip, ip, 15);
    queued_ip[15] = 0;
}
int cs_test_writes(void) { return writes; }
int cs_test_sends(void) { return sends; }
int cs_test_saves(void) { return saves; }
size_t cs_test_sent(void *data) {
    memcpy(data, sent, sent_len);
    return sent_len;
}
void cs_test_time(uint64_t time) { now = time; }
int cs_receive(void *out, size_t cap, char *ip) {
    if (!queued_len)
        return 0;
    size_t len = queued_len;
    queued_len = 0;
    if (len > cap)
        return 0;
    memcpy(out, queued, len);
    strcpy(ip, queued_ip);
    return (int)len;
}
int cs_send(const char *ip, const void *data, size_t len) {
    memcpy(sent, data, len);
    sent_len = len;
    sends++;
    return 1;
}
int cs_clip_write(int kind, const unsigned char *data, size_t len, const char *name) {
    writes++;
    return 1;
}
void cs_test_copy(const char *text) {
    free(local_text);
    local_text = malloc(strlen(text) + 1);
    strcpy(local_text, text);
}
int cs_clip_read(cs_clip *out) {
    if (!local_text)
        return 0;
    memset(out, 0, sizeof(*out));
    out->kind = 1;
    out->len = strlen(local_text);
    out->data = (unsigned char *)local_text;
    local_text = NULL;
    return 1;
}
void cs_clip_free(cs_clip *out) { free(out->data); }
int cs_save(const void *data, size_t len) {
    saves++;
    return 1;
}
int cs_load(void *data, size_t cap) { return 0; }
int cs_storage_init(void) { return 1; }
int cs_net_init(void) { return 1; }
void cs_net_close(void) {}
void cs_announce(const void *data, size_t len) {}
int cs_discover(void *out, size_t cap, char *ip) { return 0; }
void cs_hostname(char *out, size_t cap) { strncpy(out, "Test device", cap); }
int cs_random(void *data, size_t len) {
    static unsigned int state = 42;
    unsigned char *p = data;
    while (len--) {
        state = state * 1664525 + 1013904223;
        *p++ = (unsigned char)(state >> 24);
    }
    return 1;
}
uint64_t cs_millis(void) { return now; }
int cs_init(void) { return 1; }
void cs_pump(void) {}
void cs_refresh(void) {}
void cs_notice(const char *title, const char *text) { notices++; }
int cs_prompt(const char *title, const char *text, char *out, size_t cap) { return 0; }

void cs_shutdown(void) {}

/* Guard the hand-written Zig 0.17 FFI declarations against C layout drift. */
size_t cs_test_clip_size(void) { return sizeof(cs_clip); }
size_t cs_test_clip_alignment(void) { return _Alignof(cs_clip); }
size_t cs_test_clip_offset(int field) {
    const size_t offsets[] = {offsetof(cs_clip, kind), offsetof(cs_clip, len),
                              offsetof(cs_clip, data), offsetof(cs_clip, name)};
    return offsets[field];
}

int cs_pair_send(const char *ip, const void *data, size_t len) { return cs_send(ip, data, len); }
void cs_pair_close(void) {}
const char *cs_net_error(void) { return "Test connection failed"; }
void cs_pairing_show(const char *code) { pairing_visible = 1; }
void cs_pairing_hide(void) { pairing_visible = 0; }
int cs_test_pairing_visible(void) { return pairing_visible; }
int cs_test_notices(void) { return notices; }

void cs_peer_authorized(const char *ip) {}
int cs_peer_connected(const char *ip) { return 1; }
void cs_peer_forget(const char *ip) {}

int cs_pair_status(void) { return 2; }

void cs_log_event(const char *stage, const unsigned char *event, const unsigned char *wire,
                  const char *peer, int kind, size_t bytes, uint64_t elapsed_ms) {
    if (log_count >= 64)
        return;
    strncpy(log_stages[log_count], stage, 39);
    memset(log_events[log_count], 0, 16);
    if (event)
        memcpy(log_events[log_count], event, 16);
    log_count++;
}
int cs_test_log_count(void) { return log_count; }
const char *cs_test_log_stage(int i) { return log_stages[i]; }
const unsigned char *cs_test_log_event(int i) { return log_events[i]; }

void cs_log_init(const char *version) {}

int cs_send_control(const char *ip, const void *data, size_t len) { return cs_send(ip, data, len); }
