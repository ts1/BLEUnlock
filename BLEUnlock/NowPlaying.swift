import Foundation
import CoreFoundation

private func getMediaRemoteBundle() -> CFBundle {
    return CFBundleCreate(
        kCFAllocatorDefault,
        NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
    )
}

private func sendCommand(_ command: Int) {
    typealias funcType = @convention(c) (Int, NSDictionary?) -> Void
    guard let ptr = CFBundleGetFunctionPointerForName(
        getMediaRemoteBundle(),
        "MRMediaRemoteSendCommand" as CFString
    ) else { return }
    let MRMediaRemoteSendCommand = unsafeBitCast(ptr, to: funcType.self)
    MRMediaRemoteSendCommand(command, nil)
}

func NowPlayingIsPlaying(_ closure: @escaping (Bool) -> Void) {
    typealias funcType = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    guard let ptr = CFBundleGetFunctionPointerForName(
        getMediaRemoteBundle(),
        "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
    ) else {
        closure(false)
        return
    }
    let MRMediaRemoteIsPlaying = unsafeBitCast(ptr, to: funcType.self)
    MRMediaRemoteIsPlaying(DispatchQueue.main, closure)
}

func NowPlayingPlay() {
    sendCommand(0) // MRMediaRemoteCommandPlay
}

func NowPlayingPause() {
    sendCommand(1) // MRMediaRemoteCommandPause
}
