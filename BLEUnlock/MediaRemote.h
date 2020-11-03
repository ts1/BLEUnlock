#include <CoreFoundation/CoreFoundation.h>

typedef enum {
    MRCommandPlay,
    MRCommandPause,
} MRCommand;

typedef void (^MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion)(Boolean isPlaying);
void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion completion);
Boolean MRMediaRemoteSendCommand(MRCommand command, id userInfo);
