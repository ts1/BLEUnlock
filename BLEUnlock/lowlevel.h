#ifndef lowlevel_h
#define lowlevel_h
#include <stdbool.h>

void setSleepNotification(void);
void wakeDisplay(void);
bool lockScreen(void);

// callback
void onDisplaySleep(void);
void onDisplayWake(void);


#endif /* lowlevel_h */
