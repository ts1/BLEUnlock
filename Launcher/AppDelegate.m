#import "AppDelegate.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

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
    [[NSWorkspace sharedWorkspace] launchApplication:mainPath];
    [NSApp terminate:self];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
