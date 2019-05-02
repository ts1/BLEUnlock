#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

void wakeDisplay(void)
{
    IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR(""), kIOPMUserActiveLocal, &assertionID);
}

bool lockScreen(void)
{
    // Go to lock screen by private API. Doesn't work in Sandbox.
    extern int SACLockScreenImmediate(void);
    return SACLockScreenImmediate() == 0;
}

void sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}
