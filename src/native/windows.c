#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include "bridge.h"
#include "tray_resources.h"
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static HWND window;
static HWND pairingWindow;
static NOTIFYICONDATAW tray;
static DWORD lastSequence;
static int clipboardListener;
static HMENU menu;
static int menuDirty = 1, menuTracking;
static unsigned char historyIds[10][32];
static void rebuild_menu(void);
static int trayVariant = -1, trayWidth, trayHeight;
static int tray_icon_variant(void) {
    HIGHCONTRASTW contrast = {0};
    contrast.cbSize = sizeof(contrast);
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
        (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
        COLORREF ink = GetSysColor(COLOR_WINDOWTEXT);
        return GetRValue(ink) + GetGValue(ink) + GetBValue(ink) > 3 * 127 ? CS_ICON_DARK_TASKBAR
                                                                          : CS_ICON_LIGHT_TASKBAR;
    }
    DWORD light = 0, bytes = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER,
                 L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"SystemUsesLightTheme", RRF_RT_REG_DWORD, NULL, &light, &bytes);
    return light ? CS_ICON_LIGHT_TASKBAR : CS_ICON_DARK_TASKBAR;
}
static int update_tray_icon(void) {
    if (!tray.hWnd)
        return 0;
    int variant = tray_icon_variant();
    int width = GetSystemMetrics(SM_CXSMICON), height = GetSystemMetrics(SM_CYSMICON);
    if (tray.hIcon && variant == trayVariant && width == trayWidth && height == trayHeight)
        return 1;
    HICON image = (HICON)LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(variant), IMAGE_ICON,
                                    width, height, 0);
    if (!image)
        return 0;
    HICON previous = tray.hIcon;
    tray.hIcon = image;
    trayVariant = variant;
    trayWidth = width;
    trayHeight = height;
    if (previous) {
        Shell_NotifyIconW(NIM_MODIFY, &tray);
        DestroyIcon(previous);
    }
    return 1;
}
static WCHAR *wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (!n)
        return NULL;
    WCHAR *p = malloc(n * sizeof(WCHAR));
    if (p)
        MultiByteToWideChar(CP_UTF8, 0, s, -1, p, n);
    return p;
}
static void add(HMENU m, const char *text, int code, int index) {
    WCHAR *w = wide(text);
    AppendMenuW(m, code ? MF_STRING : MF_STRING | MF_GRAYED, code * 100 + index, w ? w : L"");
    free(w);
}
static HMENU compact_popup(void) {
    HMENU popup = CreatePopupMenu();
    MENUINFO info = {0};
    info.cbSize = sizeof(info);
    info.fMask = MIM_STYLE;
    info.dwStyle = MNS_NOCHECK;
    SetMenuInfo(popup, &info);
    return popup;
}
static LRESULT CALLBACK proc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_SETTINGCHANGE || msg == WM_THEMECHANGED || msg == WM_SYSCOLORCHANGE ||
        msg == WM_DPICHANGED) {
        update_tray_icon();
        return 0;
    }
    if (msg == WM_CLIPBOARDUPDATE) {
        if (GetClipboardSequenceNumber() != lastSequence) {
            cs_log_event("clipboard_change_notified", NULL, NULL, "local", 0, 0, 0);
            cs_clipboard_changed();
        }
        return 0;
    }
    if (msg == WM_TIMER && w == 1) {
        cs_tick();
        return 0;
    }
    if (msg == WM_APP + 1 && (l == WM_RBUTTONUP || l == WM_LBUTTONUP)) {
        cs_tick();
        if (menuDirty)
            rebuild_menu();
        int startup = cs_startup_status();
        CheckMenuItem(menu, 800, MF_BYCOMMAND | (startup == 1 ? MF_CHECKED : MF_UNCHECKED));
        EnableMenuItem(menu, 800, MF_BYCOMMAND | (startup < 0 ? MF_GRAYED : MF_ENABLED));
        POINT p;
        GetCursorPos(&p);
        SetForegroundWindow(h);
        menuTracking = 1;
        int id = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, p.x, p.y, 0, h, NULL);
        menuTracking = 0;
        if (id / 100 == 1)
            cs_restore_history(historyIds[id % 100]);
        else if (id)
            cs_action(id / 100, id % 100);
        PostMessageW(h, WM_NULL, 0, 0);
        return 0;
    }
    if (msg == WM_DESTROY) {
        Shell_NotifyIconW(NIM_DELETE, &tray);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}
int cs_init(void) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ClipboardSyncTray";
    RegisterClassW(&wc);
    window = CreateWindowW(wc.lpszClassName, L"Clipboard Sync", 0, 0, 0, 0, 0, NULL, NULL,
                           wc.hInstance, NULL);
    if (!window)
        return 0;
    memset(&tray, 0, sizeof(tray));
    tray.cbSize = sizeof(tray);
    tray.hWnd = window;
    tray.uID = 1;
    tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray.uCallbackMessage = WM_APP + 1;
    if (!update_tray_icon())
        return 0;
    wcscpy(tray.szTip, L"Clipboard Sync");
    lastSequence = GetClipboardSequenceNumber() - 1;
    clipboardListener = AddClipboardFormatListener(window);
    if (!clipboardListener)
        cs_log_event("clipboard_notifications_unavailable", NULL, NULL, "local", 0, 0, 0);
    SetTimer(window, 1, 20, NULL);
    return Shell_NotifyIconW(NIM_ADD, &tray) != 0;
}
void cs_pump(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    Sleep(20);
}
void cs_refresh(void) { menuDirty = 1; }
static void rebuild_menu(void) {
    if (menuTracking)
        return;
    menuDirty = 0;
    if (menu)
        DestroyMenu(menu);
    menu = CreatePopupMenu();
    HMENU paired = compact_popup();
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
    WCHAR *status = wide(cs_status());
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)paired, status ? status : L"Paired devices");
    free(status);
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    int count = 0;
    for (int i = 0; i < 10; i++) {
        const char *s = cs_history_label(i);
        if (*s) {
            cs_history_id(i, historyIds[i]);
            add(menu, s, 1, i);
            count++;
        }
    }
    if (!count)
        add(menu, "Copy text or a small file to begin", 0, 0);
    HMENU devices = compact_popup();
    add(devices, "Allow a new device…", 2, 0);
    add(devices, "Connect by IP address…", 4, 0);
    for (int i = 0; i < 16; i++) {
        const char *s = cs_nearby_label(i);
        if (*s)
            add(devices, s, 3, i);
    }
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)devices, L"Connect");
    add(menu, cs_sync_action_label(), 5, 0);
    add(menu, "Launch at login", 8, 0);
    add(menu, "Quit Clipboard Sync", 7, 0);
}
static LRESULT CALLBACK pairing_proc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_CLOSE) {
        DestroyWindow(h);
        return 0;
    }
    if (msg == WM_DESTROY) {
        if (pairingWindow == h)
            pairingWindow = NULL;
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}
void cs_pairing_hide(void) {
    if (pairingWindow)
        DestroyWindow(pairingWindow);
    pairingWindow = NULL;
}
void cs_pairing_show(const char *code) {
    cs_pairing_hide();
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = pairing_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ClipboardSyncPairingCode";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    pairingWindow = CreateWindowExW(WS_EX_DLGMODALFRAME, wc.lpszClassName, L"Allow a new device",
                                    WS_CAPTION | WS_SYSMENU | WS_VISIBLE, CW_USEDEFAULT,
                                    CW_USEDEFAULT, 530, 225, window, NULL, wc.hInstance, NULL);
    CreateWindowW(L"STATIC",
                  L"On the other computer, select this device and enter this code.\nYou can leave "
                  L"this window open.",
                  WS_CHILD | WS_VISIBLE, 20, 16, 480, 44, pairingWindow, NULL, wc.hInstance, NULL);
    WCHAR *value = wide(code);
    HWND number = CreateWindowW(L"EDIT", value, WS_CHILD | WS_VISIBLE | ES_CENTER | ES_READONLY, 20,
                                68, 480, 52, pairingWindow, NULL, wc.hInstance, NULL);
    free(value);
    SendMessageW(number, WM_SETFONT, (WPARAM)GetStockObject(SYSTEM_FIXED_FONT), TRUE);
    CreateWindowW(L"STATIC",
                  L"Expires in two minutes. Five attempts maximum.\nOne device per code.",
                  WS_CHILD | WS_VISIBLE, 20, 132, 480, 44, pairingWindow, NULL, wc.hInstance, NULL);
    SetForegroundWindow(pairingWindow);
}
void cs_notice(const char *title, const char *text) {
    WCHAR *t = wide(title), *s = wide(text);
    MessageBoxW(window, s ? s : L"", t ? t : L"Clipboard Sync", MB_OK | MB_ICONINFORMATION);
    free(t);
    free(s);
}
static int promptDone, promptOK;
static HWND promptEdit;
static LRESULT CALLBACK prompt_proc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_COMMAND && (LOWORD(w) == IDOK || LOWORD(w) == IDCANCEL)) {
        promptOK = LOWORD(w) == IDOK;
        promptDone = 1;
        return 0;
    }
    if (msg == WM_CLOSE) {
        promptDone = 1;
        promptOK = 0;
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}
int cs_prompt(const char *title, const char *text, char *out, size_t cap) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = prompt_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ClipboardSyncPrompt";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    WCHAR *t = wide(title), *s = wide(text);
    HWND h = CreateWindowExW(WS_EX_DLGMODALFRAME, wc.lpszClassName, t,
                             WS_CAPTION | WS_SYSMENU | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT,
                             600, 220, window, NULL, wc.hInstance, NULL);
    free(t);
    CreateWindowW(L"STATIC", s, WS_CHILD | WS_VISIBLE, 16, 16, 550, 55, h, NULL, wc.hInstance,
                  NULL);
    free(s);
    promptEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                 WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 16, 80, 550,
                                 28, h, NULL, wc.hInstance, NULL);
    CreateWindowW(L"BUTTON", L"Connect", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 370,
                  125, 90, 30, h, (HMENU)IDOK, wc.hInstance, NULL);
    CreateWindowW(L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 475, 125, 90, 30, h,
                  (HMENU)IDCANCEL, wc.hInstance, NULL);
    EnableWindow(window, FALSE);
    SetForegroundWindow(h);
    SetFocus(promptEdit);
    promptDone = promptOK = 0;
    MSG msg;
    while (!promptDone && GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(h, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    WCHAR value[256];
    GetWindowTextW(promptEdit, value, 256);
    int n = WideCharToMultiByte(CP_UTF8, 0, value, -1, out, (int)cap, NULL, NULL);
    EnableWindow(window, TRUE);
    DestroyWindow(h);
    return promptOK && n > 0;
}
int cs_clip_read(cs_clip *out) {
    DWORD seq = GetClipboardSequenceNumber();
    if (seq == lastSequence)
        return 0;
    uint64_t started = cs_millis();
    if (!OpenClipboard(window)) {
        cs_log_event("clipboard_read_busy", NULL, NULL, "local", 0, 0, cs_millis() - started);
        return 0;
    }
    cs_log_event("clipboard_read_started", NULL, NULL, "local", 0, 0, 0);
    memset(out, 0, sizeof(*out));
    int ok = 0, retry = 0;
    if (IsClipboardFormatAvailable(CF_HDROP)) {
        HDROP drop = (HDROP)GetClipboardData(CF_HDROP);
        retry = drop == NULL;
        if (drop && DragQueryFileW(drop, 0xFFFFFFFF, NULL, 0) == 1) {
            WCHAR path[32768];
            if (DragQueryFileW(drop, 0, path, 32768)) {
                FILE *f = _wfopen(path, L"rb");
                if (f) {
                    _fseeki64(f, 0, SEEK_END);
                    long long size = _ftelli64(f);
                    rewind(f);
                    if (size >= 0 && size <= CS_MAX) {
                        out->data = malloc((size_t)size + 1);
                        if (out->data && fread(out->data, 1, (size_t)size, f) == (size_t)size) {
                            out->len = (size_t)size;
                            out->kind = 2;
                            const WCHAR *name = path;
                            for (const WCHAR *p = path; *p; p++)
                                if (*p == L'\\' || *p == L'/')
                                    name = p + 1;
                            ok = WideCharToMultiByte(CP_UTF8, 0, name, -1, out->name, 256, NULL,
                                                     NULL) > 0;
                        }
                    }
                    fclose(f);
                }
            }
        }
    } else if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HGLOBAL mem = GetClipboardData(CF_UNICODETEXT);
        const WCHAR *w = mem ? GlobalLock(mem) : NULL;
        retry = w == NULL;
        if (w) {
            size_t units = GlobalSize(mem) / sizeof(WCHAR);
            size_t len = 0;
            while (len < units && w[len])
                len++;
            if (len < units && len <= CS_MAX) {
                int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, w, (int)len, NULL, 0,
                                            NULL, NULL);
                if ((n > 0 || len == 0) && n <= CS_MAX) {
                    out->data = malloc((size_t)n + 1);
                    if (out->data) {
                        WideCharToMultiByte(CP_UTF8, 0, w, (int)len, (char *)out->data, n, NULL,
                                            NULL);
                        out->len = n;
                        out->kind = 1;
                        ok = 1;
                    }
                }
            }
            GlobalUnlock(mem);
        }
    }
    CloseClipboard();
    if (!retry)
        lastSequence = seq;
    cs_log_event(ok ? "clipboard_read_complete" : "clipboard_read_unavailable", NULL, NULL, "local",
                 out->kind, out->len, cs_millis() - started);
    if (!ok)
        cs_clip_free(out);
    return ok;
}
int cs_clip_write(int kind, const unsigned char *data, size_t len, const char *name) {
    HGLOBAL mem = NULL;
    UINT format;
    if (kind == 2) {
        const char *path = cs_save_file(data, len, name);
        if (!path)
            return 0;
        WCHAR *w = wide(path);
        if (!w)
            return 0;
        size_t bytes = (wcslen(w) + 2) * sizeof(WCHAR);
        mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + bytes);
        if (!mem) {
            free(w);
            return 0;
        }
        DROPFILES *drop = GlobalLock(mem);
        drop->pFiles = sizeof(DROPFILES);
        drop->fWide = TRUE;
        memcpy((char *)drop + sizeof(DROPFILES), w, bytes - sizeof(WCHAR));
        GlobalUnlock(mem);
        free(w);
        format = CF_HDROP;
    } else {
        int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)data, (int)len,
                                    NULL, 0);
        if (n == 0 && len)
            return 0;
        mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (n + 1) * sizeof(WCHAR));
        if (!mem)
            return 0;
        WCHAR *w = GlobalLock(mem);
        MultiByteToWideChar(CP_UTF8, 0, (const char *)data, (int)len, w, n);
        GlobalUnlock(mem);
        format = CF_UNICODETEXT;
    }
    if (!OpenClipboard(window)) {
        GlobalFree(mem);
        return 0;
    }
    EmptyClipboard();
    int ok = SetClipboardData(format, mem) != NULL;
    CloseClipboard();
    if (!ok)
        GlobalFree(mem);
    else
        lastSequence = GetClipboardSequenceNumber();
    return ok;
}

void cs_shutdown(void) {
    if (clipboardListener)
        RemoveClipboardFormatListener(window);
    KillTimer(window, 1);
    cs_pairing_hide();
    DestroyWindow(window);
    if (tray.hIcon) {
        DestroyIcon(tray.hIcon);
        tray.hIcon = NULL;
    }
    if (menu)
        DestroyMenu(menu);
}
