import Testing

@testable import PlayFXProtocol

@Suite struct RPCryptTests {
    // docs/protocol/rpcrypt.md section 3.
    @Test func tableChecksums() {
        let expected: [(String, [UInt8], Int, String)] = [
            ("p9-nonce-mask", RPTables.p9NonceMask, 16, "3083df1d0164f85f72eadfafdd1540b1c99fecaf6812099c0015367e2bde2df9"),
            ("p9-mask", RPTables.p9Mask, 16, "1765b69e117a12e22040374414d877f3af2d0eb0026495b9bee9c192a29d9a8b"),
            ("p9-regist-key", RPTables.p9RegistKey, 16, "5575c2a21c0d04ef2d8d0a5a9ff6208b7544824471d9ed73513eeafd80e45dde"),
            ("session-seed-ps4", RPTables.sessionSeedPs4, 3584, "2966fd3c1ba2fdd1fdeb8db5fbd9ef6fa41e4b4b351a724a36e653ffcd786696"),
            ("session-seed-ps5", RPTables.sessionSeedPs5, 3584, "1db53dc52e9259b87d3b4e6c93ed008eb3aeed3a05d8dbeb27ce12c92511beb9"),
            ("session-key-ps4", RPTables.sessionKeyPs4, 3584, "42a65bb3ca48909313574cd37805bf0435f78cfc884538f828dffb343042286e"),
            ("session-key-ps5", RPTables.sessionKeyPs5, 3584, "22f6776ae81cc9bf2e562abee4618e3a32557875af5cd346145a5f2a5d81009b"),
            ("regist-key-ps4", RPTables.registKeyPs4, 512, "e7d94548c4b9dba6076a89ba1dfb466cf7b635fcbc4e9efc8ec844d946c6df75"),
            ("regist-key-ps5", RPTables.registKeyPs5, 512, "53b11608360076562655967ca89d6bd5e9b8c05220644075bb49876c95cd3965"),
            ("regist-mask-ps4", RPTables.registMaskPs4, 512, "4aacf71fe36d53b46faa277a04c73e3c115eb3d4b4ae7732e919a6d1b35f5f54"),
            ("regist-mask-ps5", RPTables.registMaskPs5, 512, "3299d292a30e9be23c16a79bdd1a7cf8862a973ead751fd20d6d7c48154edeb0"),
            ("iv-hmac-key-p9", RPTables.ivHmacKeyP9, 16, "3a38d06e6602d3f284dc066037187ba37e3f81fabf2cd5ef4f13403ed21899a8"),
            ("iv-hmac-key-ps4", RPTables.ivHmacKeyPs4, 16, "4942743098a7bad11e2be8c2e899d3fcae52de3fc4df4edeafd979d734c31818"),
            ("iv-hmac-key-ps5", RPTables.ivHmacKeyPs5, 16, "880c56eda992313f9aaa57e70e725b72b4371253beba1fabf60a83fe3d429a37"),
        ]
        for (name, bytes, count, digest) in expected {
            #expect(bytes.count == count, "\(name) size")
            #expect(sha256Hex(bytes) == digest, "\(name) sha256")
        }
    }

    @Test func hmacKeys() {
        #expect(RPCryptContext.hmacKey(for: .ps4v8) == hex("ac078883c83a1fe811463af39ee3e377"))
        #expect(RPCryptContext.hmacKey(for: .ps4v9) == hex("ac078883c83a1fe811463af39ee3e377"))
        #expect(RPCryptContext.hmacKey(for: .ps4v10) == hex("20d66f5904ea7c14e557ffc52e488ac8"))
        #expect(RPCryptContext.hmacKey(for: .ps5v1) == hex("464687b349ca8ce859c5270f5d7a69d6"))
    }

    struct SessionCase: Sendable {
        var target: RPTarget
        var key, seed, iv0, iv1, ivBig, ciphertext, keystream: String
    }

    static let sessionCases = [
        SessionCase(
            target: .ps4v9, key: "0072967383a3888e49ec63fc477adc7a", seed: "795db676d2b15006d9faa000cb5470c3",
            iv0: "0f10be874cc7f9bad9f9ce433033709a", iv1: "661e4acd6aac6d7f25ed7f1a581e0bbd",
            ivBig: "4b5f8a2ddaf63da041cc275ae5be1859",
            ciphertext: "301b27ac03bfc1d86756a4667b8e98ace005241987d324e1e87e427993dd67255a2a8932ef06",
            keystream: "7d1e15fb7b040569b3d103b9b5197aa6562f503289a6931f611362f84355312b9d71bc9b752d"),
        SessionCase(
            target: .ps4v8, key: "0072967383a3888e49ec63fc477adc7a", seed: "795db676d2b15006d9faa000cb5470c3",
            iv0: "0f10be874cc7f9bad9f9ce433033709a", iv1: "661e4acd6aac6d7f25ed7f1a581e0bbd",
            ivBig: "4b5f8a2ddaf63da041cc275ae5be1859",
            ciphertext: "301b27ac03bfc1d86756a4667b8e98ace005241987d324e1e87e427993dd67255a2a8932ef06",
            keystream: "7d1e15fb7b040569b3d103b9b5197aa6562f503289a6931f611362f84355312b9d71bc9b752d"),
        SessionCase(
            target: .ps4v10, key: "7fc2079c248c4bfd9757b28add09b9d5", seed: "d7a0bebce46050c88357d9c895005820",
            iv0: "505df3da9186e52cf7e97045eb2ded0d", iv1: "5e835e6f13f0f7f56826e02a7447c918",
            ivBig: "0b9005de1c59b8c7b0e1e384dd939ba5",
            ciphertext: "f33853b5115cb4ec3b25cf70b444bbe50087535e04a70d2e78dbc20dded35b24a3f3131252c3",
            keystream: "003eca643c3c6743a1389f0653fbeec5a2f7776858cba6aa2f3279bbc2485e19477dca330ed8"),
        SessionCase(
            target: .ps5v1, key: "0d2d5679e889b82040692955128dfab5", seed: "3702cc25ab3e19c6e185321596443ba9",
            iv0: "4a680df9eda7a382a183e9f29e6d36ee", iv1: "2c256fff5ef4f8de3ce0600365e256e6",
            ivBig: "73e809923b34526891c4c7f6847634c8",
            ciphertext: "c65fa154cfc3ab08748f4f33d22090821c620b45935917205db08a0f28f667cedc30802ef514",
            keystream: "bad59a62345fbe31e3920175c6de40a9854f6d2349904d9fae075ac6fd6527105063d645e25c"),
    ]

    @Test(arguments: sessionCases) func sessionMode(_ c: SessionCase) throws {
        let context = try RPCryptContext.session(target: c.target, nonce: Vector.nonce, rpKey: Vector.rpKey)
        #expect(context.key == hex(c.key))
        #expect(context.seed == hex(c.seed))
        #expect(context.hmacKey == RPCryptContext.hmacKey(for: c.target))
        #expect(context.iv(counter: 0) == hex(c.iv0))
        #expect(context.iv(counter: 1) == hex(c.iv1))
        #expect(context.iv(counter: 0x0102030405060708) == hex(c.ivBig))

        let encrypted = try context.encrypted(Vector.plaintext, counter: 5)
        #expect(encrypted == hex(c.ciphertext))
        #expect(try context.decrypted(encrypted, counter: 5) == Vector.plaintext)

        var stream = Vector.plaintext
        try context.xorKeystream(&stream)
        #expect(stream == hex(c.keystream))
    }

    struct RegistrationCase: Sendable {
        var target: RPTarget
        var key, iv0, masked: String
    }

    static let registrationCases = [
        RegistrationCase(
            target: .ps4v9, key: "3fa0a5f8dcbb3ecc50baedef9734c7c9", iv0: "655467f6d7b9f14a6006f488702ca42e",
            masked: "07189e2ac39132cdaa6a6ff81eae6abc"),
        RegistrationCase(
            target: .ps4v8, key: "3fa0a5f8dcbb3ecc50baedef9734c7c9", iv0: "655467f6d7b9f14a6006f488702ca42e",
            masked: "07189e2ac39132cdaa6a6ff81eae6abc"),
        RegistrationCase(
            target: .ps4v10, key: "cebcb640080776047b85e85bf350f52d", iv0: "837b69ad7efb2592540fbe075c9a2e3c",
            masked: "791ffef007185a6e52e54002dd54dfe0"),
        RegistrationCase(
            target: .ps5v1, key: "d860e146bdb0bd94b460070bb1f3866d", iv0: "4f38c01a3aeb01220b00ad1c5c21feb3",
            masked: "7afd215f437e47f0c0b17cf1a1274c57"),
    ]

    @Test(arguments: registrationCases) func registrationMode(_ c: RegistrationCase) throws {
        let crypt = try RPCryptContext.registration(
            target: c.target, pin: Vector.pin, seed: Vector.seed, keyColumn: 1, maskColumn: 8)
        #expect(crypt.context.key == hex(c.key))
        #expect(crypt.context.seed == Vector.seed)
        #expect(crypt.context.iv(counter: 0) == hex(c.iv0))
        #expect(crypt.maskedSeed == hex(c.masked))
    }

    @Test func psnRegistrationMode() throws {
        let ps4 = try RPCryptContext.psnRegistration(
            target: .ps4v10, seed: Vector.seed, d1: Vector.d1, d2: Vector.d2, cd: Vector.cd,
            keyColumn: 1, maskColumn: 8)
        #expect(ps4.context.key == hex("1111f3684d7ddfddf81075c8e76ff535"))
        #expect(ps4.maskedSeed == hex("b91ffce88f9c780ef041dafae550e3e0"))
        let ps5 = try RPCryptContext.psnRegistration(
            target: .ps5v1, seed: Vector.seed, d1: Vector.d1, d2: Vector.d2, cd: Vector.cd,
            keyColumn: 1, maskColumn: 8)
        #expect(ps5.context.key == hex("526d0e33bf114990b8927f609768dc86"))
        #expect(ps5.maskedSeed == hex("927f37d1557c89f2c8fbfc73e3657489"))

        // E is the helper context's encryption of CD (test-vectors.md section 3).
        let helper = try RPCryptContext(key: Vector.d1, seed: Vector.d2, hmacKey: RPTables.ivHmacKeyPs4)
        #expect(try helper.encrypted(Vector.cd, counter: 0) == hex("dfad4528457aa9d983959d9314836156"))
    }

    @Test func inputsAreChecked() throws {
        let short = [UInt8](repeating: 0, count: 15)
        #expect(throws: RPCryptError.badLength) { try RPCryptContext(key: short, seed: Vector.seed, hmacKey: Vector.seed) }
        #expect(throws: RPCryptError.badLength) { try RPCryptContext.session(target: .ps5v1, nonce: short, rpKey: Vector.rpKey) }
        #expect(throws: RPCryptError.badLength) { try RPCryptContext.session(target: .ps5v1, nonce: Vector.nonce, rpKey: short) }
        #expect(throws: RPCryptError.badLength) {
            try RPCryptContext.registration(target: .ps5v1, pin: 1, seed: short, keyColumn: 0, maskColumn: 0)
        }
        #expect(throws: RPCryptError.unsupportedTarget) {
            try RPCryptContext.psnRegistration(
                target: .ps4v9, seed: Vector.seed, d1: Vector.d1, d2: Vector.d2, cd: Vector.cd,
                keyColumn: 0, maskColumn: 0)
        }
        #expect(throws: RPCryptError.badLength) {
            try RPCryptContext.psnRegistration(
                target: .ps5v1, seed: short, d1: Vector.d1, d2: Vector.d2, cd: Vector.cd, keyColumn: 0, maskColumn: 0)
        }
        #expect(throws: RPCryptError.badLength) {
            try RPCryptContext.psnRegistration(
                target: .ps5v1, seed: Vector.seed, d1: Vector.d1, d2: Vector.d2, cd: short, keyColumn: 0, maskColumn: 0)
        }
    }

    @Test func emptyBufferIsANoOp() throws {
        let context = try RPCryptContext.session(target: .ps5v1, nonce: Vector.nonce, rpKey: Vector.rpKey)
        var empty: [UInt8] = []
        try context.encrypt(&empty, counter: 0)
        #expect(empty.isEmpty)
    }

    /// Every length around the block size round-trips, and a counter change changes the output.
    @Test func roundTripsAllLengths() throws {
        let context = try RPCryptContext.session(target: .ps4v10, nonce: Vector.nonce, rpKey: Vector.rpKey)
        for length in 1...70 {
            let plain = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
            let cipher = try context.encrypted(plain, counter: 9)
            #expect(cipher.count == length)
            #expect(try context.decrypted(cipher, counter: 9) == plain)
            #expect(try context.encrypted(plain, counter: 10) != cipher)
        }
    }

    /// Expected values computed by an independent script (written from the spec text; tables read from the
    /// raw .hex files, HMAC from Python's stdlib, AES-CFB from `openssl enc -aes-128-cfb`).
    @Test func secondNonceRowsMatchTheIndependentScript() throws {
        // N[0] >> 3 = 0 and N[7] >> 3 = 31: the first and last table rows.
        let nonce = hex("07112233445566f8aabbccddeeff0011")
        let ps4 = try RPCryptContext.session(target: .ps4v10, nonce: nonce, rpKey: Vector.rpKey)
        #expect(ps4.key == hex("5325b4a9907e4d74eee9eeb681e5571b"))
        #expect(ps4.seed == hex("e208d8ca5048c91e1d9653ebcb632de2"))
        #expect(ps4.iv(counter: 5) == hex("99cc6f1175cae73078de24c39a991300"))
        #expect(try ps4.encrypted(Vector.plaintext, counter: 5) == hex("6f079ef3660ce00f7be9b88f3b1f8248019ee162b1b32258b9fe9fc83e0c38d8cfe4a163ae32"))
        let ps5 = try RPCryptContext.session(target: .ps5v1, nonce: nonce, rpKey: Vector.rpKey)
        #expect(ps5.key == hex("7e540aac7ee47bbec03edc6b6ef4b85e"))
        #expect(ps5.seed == hex("a54d7023541a859f561ec90082011a8c"))
        #expect(ps5.iv(counter: 5) == hex("a4943d375f297e7cb89b3b369b41d065"))
        #expect(try ps5.encrypted(Vector.plaintext, counter: 5) == hex("c3f31cf55f5100f94795e5badc33f1e87e8be8e88e1fc85fd5debcf97a62fc783a5d2c649c9c"))
    }

    /// Filler 0xa7 gives key_col = 7 and mask_col = 20 (same independent script).
    @Test func otherFillerColumnsMatchTheIndependentScript() throws {
        let ps4 = try RPCryptContext.registration(target: .ps4v10, pin: Vector.pin, seed: Vector.seed, keyColumn: 0xa7 & 0x1f, maskColumn: 0xa7 >> 3)
        #expect(ps4.context.key == hex("d07be0940088d17e6d81288034c82778"))
        #expect(ps4.maskedSeed == hex("505a7547c4854efdd6172eba944b6aef"))
        let ps5 = try RPCryptContext.registration(target: .ps5v1, pin: Vector.pin, seed: Vector.seed, keyColumn: 0xa7 & 0x1f, maskColumn: 0xa7 >> 3)
        #expect(ps5.context.key == hex("7110c26fa0ad997f342fb09622ae4abd"))
        #expect(ps5.maskedSeed == hex("7f266db1aa4e7035817440cf582922ed"))
        for (target, digest) in [(RPTarget.ps4v10, "1d10d13f1ad84563a99a386944d3a46d2143647d566349dc1e0abbe57bbbd64a"),
                                 (.ps5v1, "d3fb36eab846513ccd02b3f74046d9ce30bddd824b97c8bf5ce6e70be64d2bdf"),
                                 (.ps4v9, "d0ed21bde1b597d8ea7d06a551958686ec89c6cc125ea9284880841a42437612")] {
            let body = try RegistrationRequest.build(
                target: target, identity: .accountID(Vector.accountID), pin: Vector.pin, seed: Vector.seed, filler: 0xa7).body
            #expect(sha256Hex(body) == digest, "\(target)")
        }
    }

    @Test func hexHelpers() {
        #expect(decodeHex("0aFf".utf8) == [0x0a, 0xff])
        #expect(decodeHex("abc".utf8) == nil)
        #expect(decodeHex("zz".utf8) == nil)
        #expect(encodeHex([0, 0xab]) == "00ab")
    }
}
