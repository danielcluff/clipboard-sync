#include "bridge.h"
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
static BOOL bundledApp(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    return [bundle.bundleURL.pathExtension isEqualToString:@"app"] &&
           [bundle.bundleIdentifier isEqualToString:@"org.clipboardsync.desktop"];
}
int cs_startup_status(void) {
    if (@available(macOS 13.0, *)) {
        if (!bundledApp())
            return -1;
        switch (SMAppService.mainAppService.status) {
        case SMAppServiceStatusEnabled:
            return 1;
        case SMAppServiceStatusRequiresApproval:
            return 2;
        case SMAppServiceStatusNotRegistered:
        case SMAppServiceStatusNotFound:
            // A new bundle can report NotFound before its first registration.
            return 0;
        default:
            return -1;
        }
    }
    return -1;
}
int cs_startup_set_enabled(int enabled) {
    if (@available(macOS 13.0, *)) {
        if (!bundledApp()) {
            cs_notice("Could not change launch at login",
                      "Open Clipboard Sync.app to change this setting.");
            return 0;
        }
        SMAppService *service = SMAppService.mainAppService;
        if ((enabled && service.status == SMAppServiceStatusEnabled) ||
            (!enabled && service.status == SMAppServiceStatusNotRegistered))
            return 1;
        NSError *error = nil;
        BOOL ok = enabled ? [service registerAndReturnError:&error]
                          : [service unregisterAndReturnError:&error];
        if (enabled && service.status == SMAppServiceStatusRequiresApproval) {
            [SMAppService openSystemSettingsLoginItems];
            return 1;
        }
        if (!ok)
            cs_notice("Could not change launch at login",
                      error.localizedDescription.UTF8String
                          ?: "macOS could not update the login item.");
        return ok;
    }
    cs_notice("Launch at login unavailable", "Launch at login requires macOS 13 or later.");
    return 0;
}
void cs_startup_toggle(void) {
    if (@available(macOS 13.0, *)) {
        if (cs_startup_status() == 2) {
            [SMAppService openSystemSettingsLoginItems];
            return;
        }
    }
    cs_startup_set_enabled(cs_startup_status() != 1);
}
