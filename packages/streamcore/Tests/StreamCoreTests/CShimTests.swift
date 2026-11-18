import CChiaki
import Darwin
import Testing

/// The C shim's `pipe2()` polyfill (needed by the static libevent); not declared in its header.
@_silgen_name("pipe2")
private func shimPipe2(_ fds: UnsafeMutablePointer<Int32>, _ flags: Int32) -> Int32

@Suite struct CShimTests {
    private func pipe(flags: Int32) throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(shimPipe2(&fds, flags) == 0)
        return (fds[0], fds[1])
    }

    @Test func pipe2AppliesCloexecAndNonblock() throws {
        let (r, w) = try pipe(flags: O_CLOEXEC | O_NONBLOCK)
        defer { close(r); close(w) }
        for fd in [r, w] {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
            #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
        }
        var byte: UInt8 = 0
        #expect(read(r, &byte, 1) == -1 && errno == EAGAIN)
        byte = 42
        #expect(write(w, &byte, 1) == 1)
        byte = 0
        #expect(read(r, &byte, 1) == 1 && byte == 42)
    }

    @Test func pipe2WithoutFlagsIsAPlainPipe() throws {
        let (r, w) = try pipe(flags: 0)
        defer { close(r); close(w) }
        for fd in [r, w] {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0)
            #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == 0)
        }
    }

    /// libchiaki's ChiakiQuitReason values (session.h; "values must not change" upstream).
    @Test func classifiesQuitReasons() {
        let (stopped, inUse, ctrlUnknown, streamUnknown, remoteDisconnected, remoteShutdown) = (1, 4, 7, 10, 11, 12)
        #expect(psrp_quit_kind(Int32(inUse)) == PSRP_QUIT_BUSY)
        for dropped in [ctrlUnknown, streamUnknown, remoteDisconnected] {
            #expect(psrp_quit_kind(Int32(dropped)) == PSRP_QUIT_DROPPED)
        }
        for final in [0, stopped, 2, 3, 5, 6, 8, 9, remoteShutdown, 13] {
            #expect(psrp_quit_kind(Int32(final)) == PSRP_QUIT_FINAL)
        }
    }
}
