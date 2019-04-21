#include "lowlevel.h"

#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>

#include <mach/mach_port.h>
#include <mach/mach_interface.h>
#include <mach/mach_init.h>

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

static void
sleepCallback(void *refCon, io_service_t service, natural_t messageType, void *messageArgument)
{
    switch (messageType) {
    case kIOMessageDeviceWillPowerOff:
        onDisplaySleep();
        break;
    case kIOMessageDeviceHasPoweredOn:
        onDisplayWake();
        break;
    }
}

void setSleepNotification(void)
{
    io_service_t displayWrangler;
    IONotificationPortRef notificationPort;
    io_object_t notification;
    
    displayWrangler = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceNameMatching("IODisplayWrangler"));
    notificationPort = IONotificationPortCreate(kIOMasterPortDefault);
    IOServiceAddInterestNotification(notificationPort, displayWrangler, kIOGeneralInterest, sleepCallback, NULL, &notification);
    
    CFRunLoopAddSource (CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notificationPort), kCFRunLoopDefaultMode);
    IOObjectRelease (displayWrangler);
}

void wakeDisplay(void)
{
    IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR(""), kIOPMUserActiveLocal, &assertionID);
}

void lockScreen(void)
{
    extern void SACLockScreenImmediate(void);
    SACLockScreenImmediate();
}
