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
    @Test func runsTheFrameAndInputThreadsAsUserInteractive() {
        // ChiakiThreadName values (third_party/chiaki-ng/lib/include/chiaki/thread.h, in order from 0).
        let discovery: Int32 = 2, takion: Int32 = 4, takionSend: Int32 = 5, feedback: Int32 = 8, session: Int32 = 9,
            gkcrypt: Int32 = 11
        for name in [takion, takionSend, gkcrypt, feedback] {
            #expect(psrp_thread_qos(name) == QOS_CLASS_USER_INTERACTIVE.rawValue)
        }
        #expect(psrp_thread_qos(session) == QOS_CLASS_USER_INITIATED.rawValue)
        #expect(psrp_thread_qos(discovery) == QOS_CLASS_DEFAULT.rawValue)
    }

    @Test func classifiesQuitReasons() {
        let (stopped, inUse, ctrlUnknown, streamUnknown, remoteDisconnected, remoteShutdown) = (1, 4, 7, 10, 11, 12)
        #expect(psrp_quit_kind(Int32(inUse)) == PSRP_QUIT_BUSY)
        #expect(psrp_quit_kind(Int32(stopped)) == PSRP_QUIT_STOPPED)
        for dropped in [ctrlUnknown, streamUnknown] {
            #expect(psrp_quit_kind(Int32(dropped)) == PSRP_QUIT_DROPPED)
        }
        // The console ending the session on purpose (with a reason) isn't a drop.
        for final in [0, 2, 3, 5, 6, 8, 9, remoteDisconnected, remoteShutdown, 13] {
            #expect(psrp_quit_kind(Int32(final)) == PSRP_QUIT_FINAL)
        }
    }

    @Test func parsesPSNDeviceIDs() {
        var out = [UInt8](repeating: 0, count: 32)
        #expect(psrp_parse_duid(String(repeating: "0a", count: 31) + "ff", &out))
        #expect(out.first == 0x0a && out.last == 0xff)
        #expect(!psrp_parse_duid("0a", &out)) // too short
        #expect(!psrp_parse_duid(String(repeating: "zz", count: 32), &out)) // not hex
        #expect(!psrp_parse_duid(nil, &out))
    }

    /// libchiaki's ChiakiErrorCode values (common.h).
    @Test func explainsInternetPlayFailures() {
        let (hostDown, hostUnreach, unknown) = (Int32(8), Int32(9), Int32(1))
        #expect(String(cString: psrp_remote_error_message(hostDown)).contains("Stay connected to the internet"))
        #expect(String(cString: psrp_remote_error_message(hostUnreach)).contains("Try another network"))
        #expect(String(cString: psrp_remote_error_message(unknown)) == "Connecting over the internet failed.")
    }

    private func pairingMessage(_ error: Int32, reason: UInt32 = 0, answered: Bool = false, ps5: Bool = true) -> String {
        var out = [CChar](repeating: 0, count: 512)
        psrp_regist_error_message(error, reason, answered, ps5, &out, out.count)
        return String(cString: out)
    }

    /// libchiaki's ChiakiErrorCode values (common.h) and RP-Application-Reason codes (session.h).
    @Test func explainsPairingFailures() {
        let (unknown, parseAddr, network, refused, hostDown, hostUnreach, disconnected, timeout, httpNonOk) =
            (Int32(1), Int32(2), Int32(6), Int32(7), Int32(8), Int32(9), Int32(10), Int32(15), Int32(21))
        let (invalidData, bufTooSmall, invalidResponse) = (Int32(11), Int32(12), Int32(16))
        let (wrongPin, invalidPsnId, rpVersion, inUse) = (UInt32(0x8010_8b09), UInt32(0x8010_8b02),
                                                         UInt32(0x8010_8b11), UInt32(0x8010_8b10))
        #expect(pairingMessage(httpNonOk, reason: wrongPin, answered: true)
            == "The code is wrong or has expired. Get a new one: Pair Device on the PS5 shows a new code.")
        #expect(pairingMessage(httpNonOk, reason: wrongPin, ps5: false).contains("Add Device on the PS4"))
        #expect(pairingMessage(httpNonOk, reason: invalidPsnId).hasPrefix(
            "The PlayStation account you signed in with isn't the PS5 user who opened Pair Device."))
        #expect(pairingMessage(httpNonOk, reason: rpVersion).contains("Update the PS5's system software"))
        for noAnswer in [timeout, refused] {
            #expect(pairingMessage(noAnswer).hasPrefix("The PS5 didn't answer. Keep Pair Device open on the PS5"))
        }
        for unreachable in [network, hostDown, hostUnreach, parseAddr, disconnected] {
            #expect(pairingMessage(unreachable).contains("Privacy & Security › Local Network"))
        }
        // After the console answered, a failed connection means it stopped answering: no Local Network advice.
        for stopped in [timeout, refused, network, disconnected, unknown] {
            #expect(pairingMessage(stopped, answered: true)
                == "The PS5 stopped answering partway through pairing. Keep Pair Device open on the PS5, and pair "
                + "again with the code it shows.")
        }
        #expect(pairingMessage(timeout, answered: true, ps5: false).contains("Keep Add Device open on the PS4"))
        let fallback = "Registration failed: check the PIN (it expires after a few minutes) and that the console is on "
            + "and on the same network."
        #expect(pairingMessage(httpNonOk, reason: inUse, answered: true) == fallback)
        for unusableReply in [httpNonOk, invalidData, bufTooSmall, invalidResponse] {
            #expect(pairingMessage(unusableReply, answered: true) == fallback)
        }
        #expect(pairingMessage(unknown) == fallback)
        var tiny = [CChar](repeating: 1, count: 8)
        psrp_regist_error_message(unknown, 0, false, true, &tiny, tiny.count) // truncated, still terminated
        #expect(String(cString: tiny) == "Registr")
        psrp_regist_error_message(unknown, 0, false, true, nil, 0) // nowhere to write: no crash
    }
}

