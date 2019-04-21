#ifndef lowlevel_h
#define lowlevel_h

void setSleepNotification(void);
void wakeDisplay(void);
void lockScreen(void);

// callback
void onDisplaySleep(void);
void onDisplayWake(void);


#endif /* lowlevel_h */
