#ifndef CS_BRIDGE_H
#define CS_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#define CS_MAX (5 * 1024 * 1024)
typedef struct {
    int kind;
    size_t len;
    unsigned char *data;
    char name[256];
} cs_clip;
/* Owned clipboard data is released with cs_clip_free. kind: 1=UTF-8, 2=file. */
int cs_init(void);
void cs_pump(void);
void cs_shutdown(void);
void cs_refresh(void);
void cs_notice(const char *title, const char *text);
void cs_pairing_show(const char *code);
void cs_pairing_hide(void);
int cs_prompt(const char *title, const char *text, char *out, size_t cap);
int cs_clip_read(cs_clip *out);
int cs_clip_write(int kind, const unsigned char *data, size_t len, const char *name);
void cs_clip_free(cs_clip *clip);
int cs_read_file(const char *path, cs_clip *out);
const char *cs_save_file(const unsigned char *data, size_t len, const char *name);
int cs_storage_init(void);
int cs_load(void *data, size_t cap);
int cs_save(const void *data, size_t len);
int cs_random(void *data, size_t len);
uint64_t cs_millis(void);
/* Metadata only. event is 16 bytes, wire is a 12-byte nonce; either may be NULL. */
void cs_log_init(const char *version);
void cs_log_event(const char *stage, const unsigned char *event, const unsigned char *wire,
                  const char *peer, int kind, size_t bytes, uint64_t elapsed_ms);
void cs_hostname(char *out, size_t cap);
int cs_net_init(void);
void cs_announce(const void *data, size_t len);
int cs_discover(void *out, size_t cap, char *ip);
int cs_receive(void *out, size_t cap, char *ip);
int cs_send(const char *ip, const void *data, size_t len);
int cs_send_control(const char *ip, const void *data, size_t len);
int cs_pair_send(const char *ip, const void *data, size_t len);
void cs_pair_close(void);
int cs_pair_status(void);
void cs_peer_authorized(const char *ip);
int cs_peer_connected(const char *ip);
void cs_peer_forget(const char *ip);
const char *cs_net_error(void);
void cs_net_close(void);
/* Called by native menus. All callbacks run on the main thread. */
void cs_action(int action, int index);
int cs_is_paused(void);
const char *cs_sync_action_label(void);
void cs_poll_clipboard(void);
void cs_clipboard_changed(void);
void cs_tick(void);
int cs_history_id(int index, unsigned char *out);
void cs_restore_history(const unsigned char *hash);
const char *cs_history_label(int index);
const char *cs_peer_label(int index);
const char *cs_nearby_label(int index);
const char *cs_status(void);
#endif
