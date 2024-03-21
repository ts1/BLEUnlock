#ifndef lowlevel_h
#define lowlevel_h
#include <stdbool.h>

/// 通过MediaRemote 私有头文件私有API来进行调用锁屏
void sleepDisplay(void);
void wakeDisplay(void);
int SACLockScreenImmediate(void);

#endif /* lowlevel_h */
