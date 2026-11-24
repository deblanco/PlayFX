import Foundation

@testable import PlayFXProtocol

/// The made-up inputs of session.md section 14 and ctrl.md section 12.
enum SessionVector {
    static let host = "192.0.2.10"
    static let registKey = hex("30313233616263640000000000000000")
    static let rpKey = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
    static let nonce = hex("000102030405060708090a0b0c0d0e0f")
    static let deviceID = hex("00180000000700400080 202122232425262728292a2b2c2d2e2f 000000000000")
    static let sessionIDText = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL"

    static func context(_ target: RPTarget) throws -> RPCryptContext {
        try RPCryptContext.session(target: target, nonce: nonce, rpKey: rpKey)
    }

    /// `(sessionAesKey, sessionIvSeed)` from V-S3.
    static let keys: [(RPTarget, String, String)] = [
        (.ps5v1, "598fa9a031d01820db25cab6e90bb19b", "ac7d50f394ea6588f0488f76e4170c8a"),
        (.ps4v10, "f7e760687cea0ce70c1c129f67c087c8", "e978b89a1098296fb32415b9b5713be0"),
        (.ps4v9, "35394aed0d6cda5620d3c3a748eb1adf", "d8905e42bce052e092e354911ad33688"),
    ]
}

extension ControlEnvironment {
    /// Real sockets, but only to loopback (a test that reaches anything else fails).
    static func loopback(initPort: UInt16, ctrlPort: UInt16? = nil) -> ControlEnvironment {
        var environment = ControlEnvironment()
        environment.initPort = initPort
        environment.ctrlPort = ctrlPort ?? initPort
        environment.connectTimeout = 2
        environment.initHeaderTimeout = 1
        environment.ctrlHeaderTimeout = 1
        environment.makeInitConnection = { host, port in
            guard isLoopback(host) else { loopbackViolation("test tried to connect to non-loopback address \(host)") }
            return try NWBlockingTCPConnection(host: host, port: port)
        }
        environment.makeCtrlConnection = { host, port in
            guard isLoopback(host) else { loopbackViolation("test tried to connect to non-loopback address \(host)") }
            return try CtrlFramer.makeConnection(host: host, port: port)
        }
        return environment
    }
}


func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = monotonicSeconds() + timeout
    while monotonicSeconds() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

let sessionIDPlain = [UInt8(0x4a)] + Array(SessionVector.sessionIDText.utf8)

