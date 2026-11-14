#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include <string.h>

static inline OSStatus BLEUnlockDeterminePermissionToAutomateBundleID(CFStringRef bundleIdentifier, Boolean askUserIfNeeded) {
    if (bundleIdentifier == NULL) {
        return paramErr;
    }

    NSString *identifier = (__bridge NSString *)bundleIdentifier;
    const char *utf8 = identifier.UTF8String;
    if (utf8 == NULL) {
        return paramErr;
    }

    AEAddressDesc target = {typeNull, NULL};
    OSStatus status = AECreateDesc(typeApplicationBundleID, utf8, (Size)strlen(utf8), &target);
    if (status != noErr) {
        return status;
    }

    status = AEDeterminePermissionToAutomateTarget(&target, kCoreEventClass, kAEOpenApplication, askUserIfNeeded);
    AEDisposeDesc(&target);
    return status;
}
