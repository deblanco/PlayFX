import Darwin
import Foundation

/// A BSD UDP socket read by one dedicated user-interactive thread into a preallocated ring of buffers.
///
/// - `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` marks the traffic as interactive video (Wi-Fi WMM).
/// - Receive timestamps come from `SO_TIMESTAMP_MONOTONIC` (mach ticks, converted to `takionNow()` ns), falling
///   back to `SO_TIMESTAMP` (wall clock) if the kernel refuses it.
/// - `SO_RCVBUF` asks for 4 MiB, halving to 256 KiB, then 102400 bytes (takion.md §1.3).
/// - The thread waits in `poll` on the socket and a wake pipe, so a timer deadline costs no extra wake-ups; it
///   then drains the socket with `recvmsg` (up to one ring of datagrams) and hands each one to the handler.
final class BSDDatagramTransport: DatagramTransport, @unchecked Sendable {
    let name = "bsd"
    private let host: String
    private let port: UInt16
    private let dontFragment: Bool
    private let ringSlots: Int
    private var fd: Int32 = -1
    private var wakePipe: (read: Int32, write: Int32) = (-1, -1)
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// Guards `open`, `stopped`, `running`, `pokePending` and every use or close of the descriptors: a descriptor is
    /// closed only under this lock after `open` went false, so no `send` can ever hit a closed or recycled fd.
    private let lock = UnfairLock()
    private var open = false
    private var stopped = false
    private var running = false
    private var pokePending = false
    private(set) var timestampSource = "none"
    private(set) var receiveBufferBytes = 0
    private(set) var localPort: UInt16 = 0

    // Preallocated receive state (no allocation per packet).
    private var ring: UnsafeMutableRawPointer?
    private var control: UnsafeMutableRawPointer?
    private var iovecs: UnsafeMutablePointer<iovec>?
    private var headers: UnsafeMutablePointer<msghdr>?
    private static let slotBytes = TakionConstants.maxDatagram
    private static let controlBytes = 64
    private var monotonicStamps = false

    init(host: String, port: UInt16, dontFragment: Bool = false, ringSlots: Int = 32) {
        self.host = host
        self.port = port
        self.dontFragment = dontFragment
        self.ringSlots = ringSlots
    }

    deinit {
        releaseDescriptors()
        releaseBuffers()
    }

    /// Closes the socket and the wake pipe. Always under the lock, after `open` is false, so that a concurrent
    /// `send` either completes before the close or sees `open == false`.
    private func releaseDescriptors() {
        lock.withLock {
            open = false
            if fd >= 0 { close(fd) }
            if wakePipe.read >= 0 { close(wakePipe.read) }
            if wakePipe.write >= 0 { close(wakePipe.write) }
            fd = -1
            wakePipe = (-1, -1)
        }
    }

    private func releaseBuffers() {
        ring?.deallocate()
        control?.deallocate()
        iovecs?.deallocate()
        headers?.deallocate()
        ring = nil
        control = nil
        iovecs = nil
        headers = nil
    }

    private func setOption(_ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var v = value
        return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    func start(handler: TransportHandler) throws {
        guard let address = SocketAddress(host: host, port: port) else { throw FailureKind.badAddress }
        let ipv6 = SocketAddress.isIPv6(host)
        fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw FailureKind(errno: errno) }
        do {
            _ = setOption(SOL_SOCKET, SO_NOSIGPIPE, 1)
            _ = setOption(SOL_SOCKET, SO_NET_SERVICE_TYPE, Int32(NET_SERVICE_TYPE_VI))
            var size: Int32 = 4 << 20
            while size >= 256 << 10 {
                if setOption(SOL_SOCKET, SO_RCVBUF, size) { break }
                size /= 2
            }
            if size < 256 << 10 { _ = setOption(SOL_SOCKET, SO_RCVBUF, 102_400) }
            var actual: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actual, &length)
            receiveBufferBytes = Int(actual)
            if setOption(SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, 1) {
                monotonicStamps = true
                timestampSource = "SO_TIMESTAMP_MONOTONIC"
            } else if setOption(SOL_SOCKET, SO_TIMESTAMP, 1) {
                timestampSource = "SO_TIMESTAMP"
            }
            if dontFragment {
                _ = ipv6 ? setOption(IPPROTO_IPV6, 62 /* IPV6_DONTFRAG */, 1) : setOption(IPPROTO_IP, IP_DONTFRAG, 1)
            }
            let any = SocketAddress(host: ipv6 ? "::" : "0.0.0.0", port: 0)!
            guard any.withSockaddr({ Darwin.bind(fd, $0, $1) }) == 0 else { throw FailureKind(errno: errno) }
            guard address.withSockaddr({ connect(fd, $0, $1) }) == 0 else { throw FailureKind(errno: errno) }
            var bound = sockaddr_storage()
            var boundLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) }
            }
            localPort = withUnsafePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw FailureKind(errno: errno) }
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw FailureKind(errno: errno) }
            wakePipe = (fds[0], fds[1])
            for end in fds { _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK) }
        } catch {
            releaseDescriptors()
            throw error
        }
        ring = .allocate(byteCount: ringSlots * Self.slotBytes, alignment: 64)
        control = .allocate(byteCount: ringSlots * Self.controlBytes, alignment: 16)
        iovecs = .allocate(capacity: ringSlots)
        headers = .allocate(capacity: ringSlots)
        for i in 0..<ringSlots {
            iovecs![i] = iovec(iov_base: ring! + i * Self.slotBytes, iov_len: Self.slotBytes)
            var h = msghdr()
            h.msg_iov = iovecs! + i
            h.msg_iovlen = 1
            h.msg_control = control! + i * Self.controlBytes
            h.msg_controllen = socklen_t(Self.controlBytes)
            headers![i] = h
        }
        lock.withLock {
            open = true
            running = true
        }
        let thread = Thread { [self] in
            receiveLoop(handler)
            finished.signal()
        }
        thread.name = "playfx.takion.rx"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func send(_ bytes: UnsafeRawBufferPointer) throws {
        // The syscall runs under the lock, so `releaseDescriptors` can't close the fd mid-send. A full send queue
        // drops the datagram, as UDP does, but is reported so the caller can count it.
        let error: Int32 = lock.withLock {
            guard open, fd >= 0 else { return -1 }
            return Darwin.send(fd, bytes.baseAddress, bytes.count, 0) < 0 ? errno : 0
        }
        if error == -1 { throw FailureKind.disconnected }
        if error != 0 { throw FailureKind(errno: error) }
    }

    /// Wakes the receive thread so it re-reads its deadline. Pokes coalesce: one byte in the pipe is enough until
    /// the thread has drained it.
    func reschedule() {
        lock.withLock {
            guard wakePipe.write >= 0, !pokePending else { return }
            pokePending = true
            var byte: UInt8 = 1
            _ = write(wakePipe.write, &byte, 1)
        }
    }

    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            stopped = true
            open = false
            return running
        }
        lock.withLock {
            if wakePipe.write >= 0 && !pokePending {
                pokePending = true
                var byte: UInt8 = 1
                _ = write(wakePipe.write, &byte, 1)
            }
        }
        // The receive thread closes the descriptors itself when it leaves its loop; a caller on another thread
        // waits for that. A caller on the receive thread (a callback closing the connection) must not.
        if wasRunning, Thread.current != thread { finished.wait() }
    }

    // MARK: Receive thread

    private func receiveLoop(_ handler: TransportHandler) {
        var pollFDs = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakePipe.read, events: Int16(POLLIN), revents: 0)]
        var drain = [UInt8](repeating: 0, count: 64)
        var failure: Int32 = 0
        loop: while true {
            if lock.withLock({ stopped }) { break }
            var timeout: Int32 = -1
            if let deadline = handler.transportNextWake() {
                let now = takionNow()
                if deadline <= now {
                    handler.transportWake(now: now)
                    continue
                }
                timeout = Int32(min((deadline - now + 999_999) / 1_000_000, 60_000))
            }
            pollFDs[0].revents = 0
            pollFDs[1].revents = 0
            let ready = poll(&pollFDs, 2, timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                failure = errno
                break
            }
            if pollFDs[1].revents != 0 {
                _ = drain.withUnsafeMutableBytes { read(wakePipe.read, $0.baseAddress, $0.count) }
                lock.withLock { pokePending = false }
            }
            if pollFDs[0].revents != 0 {
                var received = 0
                while received < ringSlots {
                    headers![received].msg_controllen = socklen_t(Self.controlBytes)
                    let n = recvmsg(fd, headers! + received, 0)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        failure = errno
                        break
                    }
                    iovecs![received].iov_len = n
                    received += 1
                }
                for i in 0..<received {
                    let slot = UnsafeMutableRawBufferPointer(start: ring! + i * Self.slotBytes, count: iovecs![i].iov_len)
                    let stamp = timestamp(of: headers! + i)
                    handler.transportDidReceive(slot, at: stamp ?? takionNow(), kernelTimestamp: stamp != nil)
                    iovecs![i].iov_len = Self.slotBytes
                }
                if failure != 0 { break loop }
            }
        }
        let wasStopped = lock.withLock { () -> Bool in
            running = false
            return stopped
        }
        releaseDescriptors()
        releaseBuffers()
        if !wasStopped { handler.transportFailed(errno: failure) }
    }

    /// The receive time of a datagram from its control messages, in `takionNow()` nanoseconds.
    private func timestamp(of header: UnsafeMutablePointer<msghdr>) -> UInt64? {
        guard let base = header.pointee.msg_control else { return nil }
        let total = Int(header.pointee.msg_controllen)
        var offset = 0
        while offset + 12 <= total {
            let length = Int(base.load(fromByteOffset: offset, as: UInt32.self))
            let level = base.load(fromByteOffset: offset + 4, as: Int32.self)
            let type = base.load(fromByteOffset: offset + 8, as: Int32.self)
            guard length >= 12 else { break }
            if level == SOL_SOCKET {
                if type == SCM_TIMESTAMP_MONOTONIC, length >= 20 {
                    let ticks = base.loadUnaligned(fromByteOffset: offset + 12, as: UInt64.self)
                    return MachTime.current.nanoseconds(ticks)
                }
                if type == SCM_TIMESTAMP, length >= 12 + MemoryLayout<timeval>.size, !monotonicStamps {
                    let tv = base.loadUnaligned(fromByteOffset: offset + 12, as: timeval.self)
                    var nowWall = timeval()
                    gettimeofday(&nowWall, nil)
                    let ageMicros = (Int64(nowWall.tv_sec) - Int64(tv.tv_sec)) * 1_000_000
                        + Int64(nowWall.tv_usec) - Int64(tv.tv_usec)
                    let now = takionNow()
                    return ageMicros > 0 ? now &- min(UInt64(ageMicros) * 1000, now) : now
                }
            }
            offset += (length + 3) & ~3
        }
        return nil
    }
}
