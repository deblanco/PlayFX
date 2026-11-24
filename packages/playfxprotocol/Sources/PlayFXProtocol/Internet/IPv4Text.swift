import Darwin

/// Checks on dotted IPv4 text. Addresses from the network (a gateway's external address, an SSDP answer's
/// location) are validated here before they become a candidate or a connection target.
enum IPv4Text {
    /// The four octets when `text` is dotted IPv4 (`inet_pton`'s grammar: no leading junk, no hostnames), else nil.
    static func octets(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard text.utf8.count <= 15, inet_pton(AF_INET, text, &address) == 1 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    /// True for a valid address that is private, link-local, loopback, shared (CGNAT), unspecified, multicast or
    /// reserved: not an address the internet can reach. Documentation ranges (RFC 5737) are not counted.
    static func isNotRoutable(_ text: String) -> Bool {
        guard let o = octets(text) else { return true }
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (100, 64...127), (172, 16...31): return true
        default: return o[0] >= 224
        }
    }

    /// True for the addresses a LAN gateway can have: RFC 1918 or link-local (and loopback only when `loopback`).
    static func isLAN(_ text: String, loopback: Bool = false) -> Bool {
        guard let o = octets(text) else { return false }
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (169, 254), (172, 16...31): return true
        case (127, _): return loopback
        default: return false
        }
    }
}
