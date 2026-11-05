#include "bridge.h"
#include "tray_icon_pdf.h"
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>
static NSStatusItem *statusItem;
static NSWindow *pairingWindow;
static NSInteger lastChange = -1;
static BOOL menuDirty = YES;
static NSTimer *syncTimer;
static void populateMenu(NSMenu *menu);
static void updateStartupItem(NSMenu *menu) {
    NSMenuItem *item = [menu itemWithTag:800];
    int status = cs_startup_status();
    item.title = status == 2 ? @"Launch at login (approve in Settings…)" : @"Launch at login";
    item.state = status == 1   ? NSControlStateValueOn
                 : status == 2 ? NSControlStateValueMixed
                               : NSControlStateValueOff;
    item.action = status < 0 ? nil : @selector(action:);
    item.enabled = status >= 0;
    item.toolTip =
        status < 0 ? @"Requires macOS 13 or later and the Clipboard Sync.app bundle." : nil;
}
@interface CSDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end
@implementation CSDelegate
- (void)action:(NSMenuItem *)sender {
    if (sender.tag / 100 == 1 && [sender.representedObject isKindOfClass:[NSData class]]) {
        NSData *hash = sender.representedObject;
        if (hash.length == 32)
            cs_restore_history(hash.bytes);
    } else
        cs_action((int)(sender.tag / 100), (int)(sender.tag % 100));
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    // Only the root popup owns clipboard history. Never rebuild a submenu as the root.
    if (menu != statusItem.menu)
        return;
    // AppKit enters a tracking loop when opening a menu, before the main loop polls again.
    @autoreleasepool {
        cs_poll_clipboard();
        if (menuDirty) {
            populateMenu(menu);
            menuDirty = NO;
        }
        updateStartupItem(menu);
    }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}
@end
static CSDelegate *delegate;
static NSString *str(const char *s) { return [[NSString alloc] initWithUTF8String:s] ?: @""; }
static void add(NSMenu *menu, const char *label, int action, int index) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:str(label)
                                                  action:action ? @selector(action:) : nil
                                           keyEquivalent:@""];
    item.target = delegate;
    item.tag = action * 100 + index;
    if (action == 1) {
        unsigned char hash[32];
        if (cs_history_id(index, hash))
            item.representedObject = [NSData dataWithBytes:hash length:32];
        // Bound rendered width too, since sixty wide glyphs can exceed sixty Latin letters.
        NSDictionary *attributes = @{NSFontAttributeName : [NSFont menuFontOfSize:0]};
        NSString *title = item.title;
        NSString *prefix = title;
        while ([item.title sizeWithAttributes:attributes].width > 390 && prefix.length > 0) {
            NSRange last = [prefix rangeOfComposedCharacterSequenceAtIndex:prefix.length - 1];
            prefix = [prefix substringToIndex:last.location];
            item.title = [prefix stringByAppendingString:@"…"];
        }
    }
    [menu addItem:item];
}
int cs_init(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    delegate = [CSDelegate new];
    NSApp.delegate = delegate;
    [NSApp finishLaunching];
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *trayImage = [[NSImage alloc]
        initWithData:[NSData dataWithBytes:cs_tray_icon_pdf length:sizeof(cs_tray_icon_pdf)]];
    trayImage.size = NSMakeSize(18, 18);
    trayImage.template = YES;
    statusItem.button.title = @"";
    statusItem.button.image = trayImage;
    statusItem.button.imagePosition = NSImageOnly;
    statusItem.button.accessibilityLabel = @"Clipboard Sync";
    statusItem.button.toolTip = @"Clipboard Sync";
    NSMenu *menu = [NSMenu new];
    menu.delegate = delegate;
    statusItem.menu = menu;
    syncTimer = [NSTimer timerWithTimeInterval:0.02
                                       repeats:YES
                                         block:^(NSTimer *timer) {
                                           cs_tick();
                                         }];
    [[NSRunLoop mainRunLoop] addTimer:syncTimer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:syncTimer forMode:NSEventTrackingRunLoopMode];
    return 1;
}
static void populateMenu(NSMenu *menu) {
    [menu removeAllItems];
    NSMenuItem *pairedItem = [[NSMenuItem alloc] initWithTitle:str(cs_status())
                                                        action:nil
                                                 keyEquivalent:@""];
    NSMenu *paired = [[NSMenu alloc] initWithTitle:@"Paired devices"];
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
    pairedItem.submenu = paired;
    paired.minimumWidth = 0;
    [menu addItem:pairedItem];
    [menu addItem:[NSMenuItem separatorItem]];
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
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *devices = [[NSMenuItem alloc] initWithTitle:@"Connect"
                                                     action:nil
                                              keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Connect"];
    add(sub, "Allow a new device…", 2, 0);
    add(sub, "Connect by IP address…", 4, 0);
    [sub addItem:[NSMenuItem separatorItem]];
    for (int i = 0; i < 16; i++) {
        const char *s = cs_nearby_label(i);
        if (*s)
            add(sub, s, 3, i);
    }
    devices.submenu = sub;
    // Let AppKit compute this popup's natural size independently of the history menu.
    sub.minimumWidth = 0;
    (void)sub.size;
    [menu addItem:devices];
    add(menu, cs_sync_action_label(), 5, 0);
    NSMenuItem *sync = menu.itemArray.lastObject;
    NSString *symbol = cs_is_paused() ? @"play.fill" : @"pause.fill";
    sync.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:sync.title];
    add(menu, "Launch at login", 8, 0);
    add(menu, "Quit Clipboard Sync", 7, 0);
}
void cs_refresh(void) {
    // Keep one NSMenu for the status item. Rebuild only changed content on the next opening.
    // In particular, do not replace the tracked menu while its highlight is closing.
    menuDirty = YES;
}
void cs_pump(void) {
    @autoreleasepool {
        // Drain pending input instead of processing one event per clipboard/network cycle.
        // Mouse movement must not build an ever-growing backlog ahead of tray clicks.
        for (int i = 0; i < 64; i++) {
            NSEvent *event =
                [NSApp nextEventMatchingMask:NSEventMaskAny
                                   untilDate:i == 0 ? [NSDate dateWithTimeIntervalSinceNow:0.01]
                                                    : [NSDate distantPast]
                                      inMode:NSDefaultRunLoopMode
                                     dequeue:YES];
            if (!event)
                break;
            [NSApp sendEvent:event];
        }
        [NSApp updateWindows];
    }
}
void cs_pairing_hide(void) {
    [pairingWindow close];
    pairingWindow = nil;
}
void cs_pairing_show(const char *code) {
    cs_pairing_hide();
    pairingWindow =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 190)
                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    pairingWindow.releasedWhenClosed = NO;
    pairingWindow.title = @"Allow a new device";
    NSTextField *instructions =
        [NSTextField wrappingLabelWithString:@"On the other computer, select this device and enter "
                                             @"this code. You can leave this window open."];
    instructions.frame = NSMakeRect(24, 122, 392, 44);
    NSTextField *number = [NSTextField labelWithString:str(code)];
    number.font = [NSFont monospacedDigitSystemFontOfSize:36 weight:NSFontWeightSemibold];
    number.alignment = NSTextAlignmentCenter;
    number.selectable = YES;
    number.frame = NSMakeRect(24, 64, 392, 48);
    NSTextField *expiry =
        [NSTextField wrappingLabelWithString:
                         @"Expires in two minutes. Five attempts maximum. One device per code."];
    expiry.frame = NSMakeRect(24, 16, 392, 38);
    [pairingWindow.contentView addSubview:instructions];
    [pairingWindow.contentView addSubview:number];
    [pairingWindow.contentView addSubview:expiry];
    [pairingWindow center];
    [pairingWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
void cs_notice(const char *title, const char *text) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = str(title);
    alert.informativeText = str(text);
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}
int cs_prompt(const char *title, const char *text, char *out, size_t cap) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = str(title);
    alert.informativeText = str(text);
    [alert addButtonWithTitle:@"Connect"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 480, 24)];
    alert.accessoryView = input;
    [alert.window setInitialFirstResponder:input];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn)
        return 0;
    const char *value = input.stringValue.UTF8String;
    if (strlen(value) >= cap)
        return 0;
    strcpy(out, value);
    return 1;
}
int cs_clip_read(cs_clip *out) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        if (pb.changeCount == lastChange)
            return 0;
        lastChange = pb.changeCount;
        if ([pb.types containsObject:@"com.VoiceInk.PasteSession"])
            return 0;
        memset(out, 0, sizeof(*out));
        NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                                   options:@{
                                                       NSPasteboardURLReadingFileURLsOnlyKey : @YES
                                                   }];
        if (urls.count) {
            if (urls.count != 1)
                return 0;
            return cs_read_file(urls.firstObject.path.fileSystemRepresentation, out);
        }
        NSString *text = [pb stringForType:NSPasteboardTypeString];
        if (!text)
            return 0;
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > CS_MAX)
            return 0;
        out->data = malloc(data.length + 1);
        if (!out->data)
            return 0;
        memcpy(out->data, data.bytes, data.length);
        out->len = data.length;
        out->kind = 1;
        return 1;
    }
}
int cs_clip_write(int kind, const unsigned char *data, size_t len, const char *name) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        if (kind == 2) {
            const char *path = cs_save_file(data, len, name);
            if (!path)
                return 0;
            NSURL *url = [NSURL fileURLWithPath:str(path)];
            [pb clearContents];
            if (![pb writeObjects:@[ url ]])
                return 0;
        } else {
            NSString *text = [[NSString alloc] initWithBytes:data
                                                      length:len
                                                    encoding:NSUTF8StringEncoding];
            if (!text)
                return 0;
            [pb clearContents];
            if (![pb setString:text forType:NSPasteboardTypeString])
                return 0;
        }
        lastChange = pb.changeCount;
        return 1;
    }
}

void cs_shutdown(void) {
    [syncTimer invalidate];
    syncTimer = nil;
    cs_pairing_hide();
    [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
}
