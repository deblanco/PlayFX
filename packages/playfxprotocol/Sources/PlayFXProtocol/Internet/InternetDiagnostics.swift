import Foundation

// Text for `InternetOptions.log` (and `HolePunchOptions.log`): what a first run on an unknown network needs to be
// diagnosed from one log. Never a token, key, hashed id or sid; addresses are masked to their kind and first two octets.

enum AddressMask {
    /// `public 203.0.x.x`, `private 192.168.x.x`, `cgnat 100.64.x.x` (RFC 6598), `loopback 127.0.x.x`,
    /// `link-local 169.254.x.x`; `none` for an empty address (a LOCAL candidate without a LAN address) and `invalid`
    /// for anything that isn't dotted IPv4.
    static func describe(_ address: String) -> String {
        if address.isEmpty { return "none" }
        guard let o = IPv4Text.octets(address) else { return "invalid" }
        let kind: String
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (172, 16...31): kind = "private"
        case (100, 64...127): kind = "cgnat"
        case (127, _): kind = "loopback"
        case (169, 254): kind = "link-local"
        case (0, _): kind = "unspecified"
        default: kind = o[0] >= 224 ? "reserved" : "public"
        }
        return "\(kind) \(o[0]).\(o[1]).x.x"
    }

    static func describe(_ address: String, port: UInt16) -> String { "\(describe(address)):\(port)" }

    /// A candidate list as one phrase: each type with its masked address, and its ports in full (the first `limit` of a
    /// long run of guesses, then how many there are).
    static func describe(_ candidates: [PunchCandidate], limit: Int = 10) -> String {
        guard !candidates.isEmpty else { return "none" }
        var groups: [(type: PunchCandidateType, address: String, ports: [UInt16])] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { $0.type == candidate.type && $0.address == candidate.address }) {
                groups[index].ports.append(candidate.port)
            } else {
                groups.append((candidate.type, candidate.address, [candidate.port]))
            }
        }
        return groups.map { group in
            let shown = group.ports.prefix(limit).map(String.init).joined(separator: ",")
            let more = group.ports.count > limit ? ",... (\(group.ports.count) ports)" : ""
            return "\(group.type.rawValue) \(describe(group.address)) port\(group.ports.count > 1 ? "s" : "") \(shown)\(more)"
        }.joined(separator: "; ")
    }
}

extension NATPrediction {
    /// Which case of holepunch.md section 3.3 the answers fell into, with the steps that decided it, as one line. `localPort`
    /// is the socket's own port the requests were sent from.
    static func explain(answers: [StunAnswer], prediction: NATPrediction?, localPort: UInt16) -> String {
        guard let prediction else { return "no STUN answer: no public address from STUN" }
        let used = Array(answers.prefix(4))
        let ports = used.map { String($0.port) }.joined(separator: ", ")
        let addresses = Set(used.map(\.address)).count
        var line = "prediction from \(used.count) answer(s), ports [\(ports)], \(addresses) public address(es): "
        let steps = zip(used.dropFirst(), used).map { Int($0.port) - Int($1.port) }
        let stepText = steps.map { String($0 & 0xffff) }.joined(separator: ", ")
        if prediction.randomAllocation {
            line += "random allocation (steps mod 65536 [\(stepText)] don't repeat), step \(prediction.increment)"
        } else if prediction.increment != 0 {
            line += "increment \(prediction.increment) (steps mod 65536 [\(stepText)]), next port \(prediction.basePort)"
        } else if used.count < 2 {
            line += "a single answer, no step to measure, port \(prediction.basePort)"
        } else if addresses > 1 {
            line += "the public address differs between servers, no usable step, port \(prediction.basePort)"
        } else if prediction.basePort == localPort {
            line += "same port (the NAT keeps local port \(localPort))"
        } else {
            line += "stable mapping, local port \(localPort) shows as \(prediction.basePort) to every server"
        }
        return line
    }
}
