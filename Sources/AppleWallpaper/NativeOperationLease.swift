import Foundation
import Darwin

/// Serializes an entire check or application episode across our processes.
/// Apple's writer does not participate; adapter conflict checks remain required.
public final class NativeOperationLease {
    private var descriptor: Int32
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("native-operation.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AppleWallpaperError.transactionBusy
        }
        descriptor = fd
    }
    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
    deinit { release() }
}
