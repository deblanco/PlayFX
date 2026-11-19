import Darwin
import Foundation

/// Files only the user may read (pairing keys, tokens), written so they never are readable by anyone else,
/// not even for a moment.
public enum PrivateFile {
    /// Writes `data` to `url`: the data goes into a new temporary file next to it, created 0600 and
    /// exclusively (no symlink followed, nothing pre-existing reused), then renamed over. A missing folder is
    /// created 0700.
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max))").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp]) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let closed = close(fd) == 0
        guard written == data.count, closed, rename(temp, url.path) == 0 else {
            unlink(temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
