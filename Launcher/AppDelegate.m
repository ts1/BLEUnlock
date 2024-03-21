#import "AppDelegate.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

/// 通过launcher调起主应用，此时没有su权限，是失败的

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSString *id = [[NSBundle mainBundle] bundleIdentifier];
    NSString *mainId = [id stringByReplacingOccurrencesOfString:@".Launcher" withString:@""];
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:mainId].count > 0) {
        [NSApp terminate:self];
    }

    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSMutableArray *components = [NSMutableArray arrayWithArray:[path pathComponents]];
    [components removeLastObject];
    [components removeLastObject];
    [components removeLastObject];
    [components removeLastObject];
    NSString *mainPath = [NSString pathWithComponents:components];
    /// Debug调起失败，提示是个文件夹
    BOOL success = [[NSWorkspace sharedWorkspace] launchApplication:mainPath];
    [NSApp terminate:self];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
