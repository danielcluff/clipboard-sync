#include "bridge.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static GtkStatusIcon *icon;
static GtkWidget *pairingWindow;
static GtkWidget *menu;
static int changed = 1;
static GtkClipboard *clipboard;
static unsigned char *owned_data;
static size_t owned_len;
static int owned_kind;
static char *owned_uri;
static void action(GtkMenuItem *item, gpointer data) {
    int tag = GPOINTER_TO_INT(data);
    const unsigned char *hash = g_object_get_data(G_OBJECT(item), "clipboard-hash");
    if (tag / 100 == 1 && hash)
        cs_restore_history(hash);
    else
        cs_action(tag / 100, tag % 100);
}
static void add(GtkWidget *m, const char *label, int code, int index) {
    GtkWidget *item = gtk_menu_item_new_with_label(label);
    if (code == 1) {
        unsigned char *hash = g_malloc(32);
        if (cs_history_id(index, hash))
            g_object_set_data_full(G_OBJECT(item), "clipboard-hash", hash, g_free);
        else
            g_free(hash);
    }
    if (code)
        g_signal_connect(item, "activate", G_CALLBACK(action), GINT_TO_POINTER(code * 100 + index));
    else
        gtk_widget_set_sensitive(item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(m), item);
}
static void popup(GtkStatusIcon *s, guint button, guint time, gpointer unused) {
    gtk_widget_show_all(menu);
    gtk_menu_popup(GTK_MENU(menu), NULL, NULL, gtk_status_icon_position_menu, s, button, time);
}
static void activate(GtkStatusIcon *s, gpointer unused) {
    popup(s, 0, gtk_get_current_event_time(), NULL);
}
static void owner_change(GtkClipboard *cb, GdkEventOwnerChange *event, gpointer unused) {
    changed = 1;
}
int cs_init(void) {
    gdk_set_allowed_backends("x11");
    if (!gtk_init_check(NULL, NULL))
        return 0;
    clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    g_signal_connect(clipboard, "owner-change", G_CALLBACK(owner_change), NULL);
    icon = gtk_status_icon_new_from_icon_name("edit-paste");
    gtk_status_icon_set_tooltip_text(icon, "Clipboard Sync");
    gtk_status_icon_set_visible(icon, TRUE);
    g_signal_connect(icon, "popup-menu", G_CALLBACK(popup), NULL);
    g_signal_connect(icon, "activate", G_CALLBACK(activate), NULL);
    return 1;
}
void cs_pump(void) {
    while (gtk_events_pending())
        gtk_main_iteration_do(FALSE);
    g_usleep(20000);
}
void cs_refresh(void) {
    if (menu && gtk_widget_get_mapped(menu))
        return;
    if (menu)
        gtk_widget_destroy(menu);
    menu = gtk_menu_new();
    GtkWidget *pairedItem = gtk_menu_item_new_with_label(cs_status());
    GtkWidget *paired = gtk_menu_new();
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(pairedItem), paired);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), pairedItem);
    int peerCount = 0;
    for (int i = 0; i < 16; i++) {
        const char *label = cs_peer_label(i);
        if (*label) {
            add(paired, label, 6, i);
            peerCount++;
        }
    }
    if (!peerCount)
        add(paired, "No paired devices", 0, 0);
    int count = 0;
    for (int i = 0; i < 10; i++) {
        const char *s = cs_history_label(i);
        if (*s) {
            add(menu, s, 1, i);
            count++;
        }
    }
    if (!count)
        add(menu, "Copy text or a small file to begin", 0, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    GtkWidget *devices = gtk_menu_item_new_with_label("Devices");
    GtkWidget *sub = gtk_menu_new();
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(devices), sub);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), devices);
    add(sub, "Allow a new device…", 2, 0);
    add(sub, "Connect by IP address…", 4, 0);
    for (int i = 0; i < 16; i++) {
        const char *s = cs_nearby_label(i);
        if (*s)
            add(sub, s, 3, i);
    }
    add(menu, cs_sync_action_label(), 5, 0);
    add(menu, "Quit Clipboard Sync", 7, 0);
    gtk_widget_show_all(menu);
}
void cs_pairing_hide(void) {
    if (pairingWindow)
        gtk_widget_destroy(pairingWindow);
}
void cs_pairing_show(const char *code) {
    cs_pairing_hide();
    pairingWindow = gtk_message_dialog_new(NULL, 0, GTK_MESSAGE_INFO, GTK_BUTTONS_CLOSE,
                                           "Pairing code: %s", code);
    gtk_window_set_title(GTK_WINDOW(pairingWindow), "Allow a new device");
    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(pairingWindow),
        "On the other computer, select this device and enter this code. You can leave this window "
        "open.\n\nExpires in two minutes. Five attempts maximum. One device per code.");
    g_signal_connect(pairingWindow, "response", G_CALLBACK(gtk_widget_destroy), NULL);
    g_signal_connect(pairingWindow, "destroy", G_CALLBACK(gtk_widget_destroyed), &pairingWindow);
    gtk_widget_show(pairingWindow);
}
void cs_notice(const char *title, const char *text) {
    GtkWidget *d = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO, GTK_BUTTONS_OK,
                                          "%s", title);
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(d), "%s", text);
    gtk_dialog_run(GTK_DIALOG(d));
    gtk_widget_destroy(d);
}
int cs_prompt(const char *title, const char *text, char *out, size_t cap) {
    GtkWidget *d =
        gtk_dialog_new_with_buttons(title, NULL, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL,
                                    "Connect", GTK_RESPONSE_OK, NULL);
    GtkWidget *box = gtk_dialog_get_content_area(GTK_DIALOG(d));
    GtkWidget *label = gtk_label_new(text), *entry = gtk_entry_new();
    gtk_widget_set_size_request(entry, 520, -1);
    gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 10);
    gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 10);
    gtk_widget_show_all(d);
    int ok = gtk_dialog_run(GTK_DIALOG(d)) == GTK_RESPONSE_OK;
    const char *value = gtk_entry_get_text(GTK_ENTRY(entry));
    if (strlen(value) >= cap)
        ok = 0;
    if (ok)
        strcpy(out, value);
    gtk_widget_destroy(d);
    return ok;
}
int cs_clip_read(cs_clip *out) {
    if (!changed)
        return 0;
    changed = 0;
    memset(out, 0, sizeof(*out));
    gchar **uris = gtk_clipboard_wait_for_uris(clipboard);
    if (uris) {
        int ok = 0;
        if (uris[0] && !uris[1]) {
            gchar *path = g_filename_from_uri(uris[0], NULL, NULL);
            if (path) {
                ok = cs_read_file(path, out);
                g_free(path);
            }
        }
        g_strfreev(uris);
        return ok;
    }
    gchar *text = gtk_clipboard_wait_for_text(clipboard);
    if (!text)
        return 0;
    size_t len = strlen(text);
    if (len > CS_MAX) {
        g_free(text);
        return 0;
    }
    out->data = malloc(len + 1);
    if (!out->data) {
        g_free(text);
        return 0;
    }
    memcpy(out->data, text, len);
    g_free(text);
    out->len = len;
    out->kind = 1;
    return 1;
}
static void provide(GtkClipboard *cb, GtkSelectionData *selection, guint info, gpointer user) {
    if (owned_kind == 1)
        gtk_selection_data_set_text(selection, (const char *)owned_data, (int)owned_len);
    else if (info == 2) {
        char *value = g_strdup_printf("copy\n%s", owned_uri);
        gtk_selection_data_set(selection,
                               gdk_atom_intern_static_string("x-special/gnome-copied-files"), 8,
                               (const guchar *)value, (int)strlen(value));
        g_free(value);
    } else {
        gchar *uris[] = {owned_uri, NULL};
        gtk_selection_data_set_uris(selection, uris);
    }
}
static void clear_owned(GtkClipboard *cb, gpointer user) {
    free(owned_data);
    owned_data = NULL;
    g_free(owned_uri);
    owned_uri = NULL;
}
int cs_clip_write(int kind, const unsigned char *data, size_t len, const char *name) {
    unsigned char *copy = NULL;
    char *uri = NULL;
    if (kind == 2) {
        const char *path = cs_save_file(data, len, name);
        if (!path)
            return 0;
        uri = g_filename_to_uri(path, NULL, NULL);
        if (!uri)
            return 0;
    } else {
        copy = malloc(len + 1);
        if (!copy)
            return 0;
        memcpy(copy, data, len);
        copy[len] = 0;
    }
    gtk_clipboard_clear(clipboard);
    owned_data = copy;
    owned_len = len;
    owned_kind = kind;
    owned_uri = uri;
    GtkTargetEntry text[] = {{"UTF8_STRING", 0, 0}, {"TEXT", 0, 0}, {"STRING", 0, 0}};
    GtkTargetEntry files[] = {{"text/uri-list", 0, 1}, {"x-special/gnome-copied-files", 0, 2}};
    int ok = gtk_clipboard_set_with_data(clipboard, kind == 2 ? files : text, kind == 2 ? 2 : 3,
                                         provide, clear_owned, NULL);
    if (!ok)
        clear_owned(clipboard, NULL);
    changed = 1;
    return ok;
}

void cs_shutdown(void) {
    cs_pairing_hide();
    gtk_status_icon_set_visible(icon, FALSE);
    g_object_unref(icon);
    if (menu)
        gtk_widget_destroy(menu);
    gtk_clipboard_clear(clipboard);
}
