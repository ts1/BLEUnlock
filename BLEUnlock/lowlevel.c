#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

void wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("BLEUnlock"), kIOPMUserActiveLocal, &assertionID);
}

bool lockScreen(void)
{
    // Go to lock screen by private API. Doesn't work in Sandbox.
    extern int SACLockScreenImmediate(void);
    return SACLockScreenImmediate() == 0;
}
