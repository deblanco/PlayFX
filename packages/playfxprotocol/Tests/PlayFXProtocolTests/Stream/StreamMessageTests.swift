import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct StreamMessageTests {
    // MARK: V-ST7 small client messages

    @Test(arguments: [
        (OutgoingStreamMessage.heartbeat, UInt16(1), "0803"),
        (OutgoingStreamMessage.streamInfoAck, UInt16(9), "080e"),
        (OutgoingStreamMessage.idrRequest, UInt16(2), "0819"),
        (OutgoingStreamMessage.corruptFrame(first: 100, last: 105), UInt16(2), "0805320408641069"),
        (OutgoingStreamMessage.controllerConnection(dualSense: true), UInt16(1), "0815b2010410011806"),
        (OutgoingStreamMessage.controllerConnection(dualSense: false), UInt16(1), "0815b2010410011802"),
        (OutgoingStreamMessage.microphoneStreamInfo, UInt16(1), "080d7a10120e01100000bb80000001e000000001"),
        (OutgoingStreamMessage.disconnect, UInt16(1), "080852160a14436c69656e7420446973636f6e6e656374696e67"),
        (OutgoingStreamMessage.probeVersionRequest, UInt16(1), "081ffa01020809"),
        (OutgoingStreamMessage.probe(.echo(enabled: true)), UInt16(8), "080c7206080012020801"),
        (OutgoingStreamMessage.probe(.echo(enabled: false)), UInt16(8), "080c7206080012020800"),
        (OutgoingStreamMessage.probe(.mtu(id: 1, requestedMtu: 1454)), UInt16(8), "080c720908011a05080110ae0b"),
        (
            OutgoingStreamMessage.probe(.clientMtu(id: 1, requestedMtu: 1454, active: true, downstreamMtu: 1454)),
            UInt16(8), "080c720e08042a0a080110ae0b180120ae0b"
        ),
        (
            OutgoingStreamMessage.probe(.clientMtu(id: 2, requestedMtu: 1454, active: false, downstreamMtu: 1454)),
            UInt16(8), "080c720e08042a0a080210ae0b180020ae0b"
        ),
        (OutgoingStreamMessage.probeHello, UInt16(1), "08001208080912001a002200"),
    ])
    func smallClientMessages(message: OutgoingStreamMessage, channel: UInt16, bytes: String) {
        #expect(message.bytes == hex(bytes))
        #expect(message.channel == channel)
        #expect(message.dataType == 0)
    }

    @Test func smallMessagesDecodeBack() throws {
        #expect(try StreamMessage.decode(hex("0803")) == .heartbeat)
        #expect(try StreamMessage.decode(hex("080e")) == .streamInfoAck)
        #expect(try StreamMessage.decode(hex("0819")) == .idrRequest)
        #expect(
            try StreamMessage.decode(hex("0805320408641069"))
                == .corruptFrame(CorruptFrameMessage(firstFrame: 100, lastFrame: 105)))
        #expect(
            try StreamMessage.decode(hex("0815b2010410011806"))
                == .controllerConnection(.connected(dualSense: true)))
        #expect(try StreamMessage.decode(hex("081ffa01020809")) == .transportVersionRequest(.probe))
        #expect(try StreamMessage.decode(hex("08001208080912001a002200")) == .hello(.probe))
    }

    @Test func wrapperHasNoPayloadForTheThreeBareTypes() {
        for type in StreamMessageType.allCases {
            let bare = [StreamMessageType.heartbeat, .streamInfoAck, .idrRequest].contains(type)
            #expect((type.payloadField == nil) == bare)
        }
        #expect(StreamMessageType.allCases.count == 33)
        #expect(!StreamMessageType.allCases.compactMap(\.payloadField).contains(7))
    }

    // MARK: V-ST5 HelloReply

    static let helloReplyHex =
        "08011a73080c10f8acd19101180120012a00" + "4241" + "04a36b48691898f4c058cd18442495b9202f859f28c9400190be3b04f5f0655c94d0b245e8ed621cdb21d24fc8b6db2309fa38dcd8b1da0c5b11786e04fc66a526"
        + "4a20" + "f1cdeeb1a7b99337b684d4462b7fce83b07eb77a2bbc24d4327a0d992cf8bccc"

    static let helloReply = HelloReplyMessage(
        serverVersion: 12, token: 0x1234_5678, keyAccepted: true, versionAccepted: true, sessionKey: "",
        ecdhPublicKey: StreamInputs.publicB, ecdhSignature: StreamInputs.signatureB)

    @Test func helloReplyMatchesTheVector() throws {
        #expect(StreamMessage.helloReply(Self.helloReply).encoded == hex(Self.helloReplyHex))
        #expect(try StreamMessage.decode(hex(Self.helloReplyHex)) == .helloReply(Self.helloReply))
    }

    @Test func helloReplyWithEveryField() throws {
        let reply = HelloReplyMessage(
            serverVersion: 1, token: 2, keyAccepted: false, versionAccepted: true, sessionKey: "k",
            extendedInfo: StreamEventInfo(code: "c", name: "n", description: "d"), serverVersionText: "v",
            ecdhPublicKey: [1], ecdhSignature: [2])
        #expect(try StreamMessage.decode(StreamMessage.helloReply(reply).encoded) == .helloReply(reply))
    }

    @Test func helloReplyOnlyNeedsTheTwoFlags() throws {
        // serverVersion, token and sessionKey absent: fine.
        let body: [UInt8] = [0x18, 0x01, 0x20, 0x01]
        let reply = try HelloReplyMessage(decoding: body)
        #expect(reply.serverVersion == nil && reply.token == nil && reply.sessionKey == nil)
        #expect(reply.keyAccepted && reply.versionAccepted)
        #expect(reply.encoded == body)
    }

    @Test func disconnectWithoutReasonStillDecodes() throws {
        let wrapper: [UInt8] = [0x08, 0x08, 0x52, 0x00]
        #expect(try StreamMessage.decode(wrapper) == .disconnect(DisconnectMessage(reason: nil)))
        #expect(DisconnectMessage(reason: nil).encoded == [0x0a, 0x00])
        #expect(try StreamInbound.parse(dataType: 0, body: wrapper) == .message(.disconnect(DisconnectMessage(reason: nil))))
    }

    @Test func malformedBodiesOfUnusedTypesStayRaw() throws {
        // A Cursor (type 6, payload field 8) with a required field missing.
        let cursor: [UInt8] = [0x08, 0x06, 0x42, 0x02, 0x08, 0x01]
        #expect(throws: ProtobufError.self) { try StreamMessage.decode(cursor) }
        #expect(
            try StreamInbound.parse(dataType: 0, body: cursor)
                == .message(.unparsed(type: .cursor, payload: [0x08, 0x01])))
        // The same for a type the client acts on is an error; so is a wrapper that doesn't read at all.
        let corrupt: [UInt8] = [0x08, 0x05, 0x32, 0x00]
        #expect(throws: ProtobufError.self) { try StreamInbound.parse(dataType: 0, body: corrupt) }
        #expect(throws: ProtobufError.self) { try StreamInbound.parse(dataType: 0, body: [0x08]) }
        // Unused type with its payload field absent altogether.
        #expect(throws: ProtobufError.self) { try StreamInbound.parse(dataType: 0, body: [0x08, 0x06]) }
        #expect(StreamMessageType.cursor.isActedOn == false && StreamMessageType.probe.isActedOn)
    }

    @Test func helloReplyMissingRequiredFieldThrows() {
        // keyAccepted missing.
        let body: [UInt8] = [0x08, 0x0c, 0x10, 0x00, 0x20, 0x01, 0x2a, 0x00]
        let wrapper = [0x08, 0x01, 0x1a, UInt8(body.count)] + body
        #expect(throws: ProtobufError.missingField("keyAccepted")) { try StreamMessage.decode(wrapper) }
        #expect(throws: ProtobufError.missingField("payload 3")) { try StreamMessage.decode([0x08, 0x01]) }
        #expect(throws: ProtobufError.missingField("type")) { try StreamMessage.decode([]) }
    }

    // MARK: V-ST6 StreamInfo

    static let streamInfoHex =
        "080d7a35" + "0a1108800f10b8081a09000000014201010160" + "0a1008800a10d0051a080000000142010101"
        + "120e0210" + "0000bb80000001e000000001"

    @Test func streamInfoFromTheConsole() throws {
        guard case .streamInfo(let info) = try StreamMessage.decode(hex(Self.streamInfoHex)) else {
            Issue.record("not a StreamInfo")
            return
        }
        #expect(info.videoProfiles.count == 2)
        #expect(info.videoProfiles[0] == VideoProfile(width: 1920, height: 1080, header: hex("000000014201010160")))
        #expect(info.videoProfiles[1] == VideoProfile(width: 1280, height: 720, header: hex("0000000142010101")))
        #expect(
            info.parsedAudioHeader
                == AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480, unknown: 1))
        #expect(info.usableProfiles.count == 2)
        #expect(StreamMessage.streamInfo(info).encoded == hex(Self.streamInfoHex))
    }

    @Test func streamInfoLimitsAndHeaderChecks() throws {
        let profiles = (0..<10).map { VideoProfile(width: $0, height: 1, header: []) }
        let info = StreamInfoMessage(
            videoProfiles: profiles, audioHeader: [1, 2, 3], startTimeout: 1, idleTimeout: 2,
            idleTimeoutDisconnect: 3, congestionInterval: 4,
            audioChannels: [StreamAudioChannel(channelType: 1, audioHeader: [9], rawPcm: true)])
        #expect(info.usableProfiles.count == 8)
        #expect(info.parsedAudioHeader == nil)
        #expect(try StreamMessage.decode(StreamMessage.streamInfo(info).encoded) == .streamInfo(info))
        #expect(StreamInfoMessage.microphone.parsedAudioHeader == MicrophoneSettings.announcedHeader)
        #expect(AudioHeader([UInt8](repeating: 0, count: 15)) == nil)
    }

    // MARK: V-ST8 console bodies

    @Test func consoleBodiesByDataType() throws {
        let disconnect = try StreamInbound.parse(
            dataType: 0, body: hex("080852160a14536572766572207368757474696e6720646f776e"))
        #expect(disconnect == .message(.disconnect(DisconnectMessage(reason: "Server shutting down"))))

        #expect(
            try StreamInbound.parse(dataType: 7, body: hex("008040"))
                == .rumble(try #require(RumbleLevels(body: [0, 128, 64]))))
        let trigger = try StreamInbound.parse(
            dataType: 11, body: hex("00 25 26 0000 0102030405060708090a 1112131415161718191a"))
        guard case .triggerEffects(let t) = trigger else {
            Issue.record("not trigger effects")
            return
        }
        #expect(t.leftMode == 0x25 && t.rightMode == 0x26)
        #expect(t.leftParameters == Array(1...10))
        #expect(t.rightParameters == Array(0x11...0x1a))
        #expect(t.unknownPair == [0, 0] && t.unknown == 0)

        let pad25 = try #require(PadInfo(body: hex("0102 0000 00000007 01 ff74a6 01 00000000000000 02 03 000000")))
        #expect(pad25.playerIndex == 1)
        #expect((pad25.red, pad25.green, pad25.blue) == (0xff, 0x74, 0xa6))
        #expect(pad25.motionReset)
        #expect(pad25.hapticsIntensity == .medium)
        #expect(pad25.triggerIntensity == .weak)
        #expect(pad25.sequence == 0x0102 && pad25.timestamp == 7)
        let pad17 = try #require(PadInfo(body: hex("02 0000ff 00 00000000000000 03 00 000000")))
        #expect(pad17.playerIndex == 2)
        #expect((pad17.red, pad17.green, pad17.blue) == (0, 0, 0xff))
        #expect(!pad17.motionReset)
        #expect(pad17.hapticsIntensity == .weak)
        #expect(pad17.triggerIntensity == .off)
        #expect(pad17.sequence == nil && pad17.timestamp == nil)
        #expect(try StreamInbound.parse(dataType: 9, body: pad17Bytes) == .padInfo(pad17))
    }

    private var pad17Bytes: [UInt8] { hex("02 0000ff 00 00000000000000 03 00 000000") }

    @Test func shortOrUnknownBodiesAreIgnored() throws {
        #expect(try StreamInbound.parse(dataType: 7, body: [0, 1]) == .ignored)
        #expect(try StreamInbound.parse(dataType: 11, body: [UInt8](repeating: 0, count: 24)) == .ignored)
        #expect(try StreamInbound.parse(dataType: 9, body: [UInt8](repeating: 0, count: 20)) == .ignored)
        #expect(try StreamInbound.parse(dataType: 3, body: [1, 2, 3]) == .ignored)
        #expect(PadInfo(body: [UInt8](repeating: 9, count: 17))?.hapticsIntensity == nil)
        #expect(throws: ProtobufError.self) { try StreamInbound.parse(dataType: 0, body: [0x08]) }
        #expect(StreamHapticsFormat.sampleRate == 3000 && StreamHapticsFormat.channels == 2)
    }

    // MARK: Round trips of every message

    @Test func everyMessageRoundTrips() throws {
        let messages: [StreamMessage] = [
            .hello(
                HelloMessage(
                    clientVersion: 12, sessionKey: "s", launchSpec: "l", encryptedKey: [0, 0, 0, 0],
                    ecdhPublicKey: [1], ecdhSignature: [2])),
            .helloReply(Self.helloReply),
            .info(try InfoMessage(decoding: (1...13).flatMap { [UInt8($0 << 3), UInt8($0)] })),
            .heartbeat,
            .packetLoss(PacketLossMessage(first: 1, last: 2, packetsReceived: 3)),
            .corruptFrame(CorruptFrameMessage(firstFrame: 65535, lastFrame: 0)),
            .cursor(CursorMessage(id: 1, width: 2, height: 3, hotspotX: 4, hotspotY: 5, pixels: [1])),
            .cursor(CursorMessage(id: 1, width: 2, height: 3, hotspotX: 4, hotspotY: 5)),
            .timer(TimerMessage(secondsLeft: 10, totalSeconds: 20)),
            .disconnect(DisconnectMessage(reason: "r", extendedInfo: StreamEventInfo(code: "c"))),
            .headerRequest(HeaderRequestMessage(kind: 1)),
            .probe(.echo(enabled: true)),
            .probe(
                ProbeMessage(
                    command: .bandwidth,
                    mtu: ProbeMtu(id: 1, requestedMtu: 2, sentMtu: 3, count: 4, sendDelay: 5, delta: 6),
                    bandwidth: ProbeBandwidth(
                        id: 1, time: 2, bandwidth: 3, fps: 4, mtu: 5, naluCount: 6, totalSent: 7, upstream: true,
                        loss: 0.5))),
            .streamInfo(.microphone),
            .streamInfoAck,
            .homeMenuCommand(HomeMenuCommandMessage(command: 2, playerId: 1)),
            .homeMenuCommand(HomeMenuCommandMessage(command: 0)),
            .connectionQuality(
                ConnectionQualityMessage(
                    targetBitrate: 1, upstreamBitrate: 2, upstreamLoss: 0.25, disableUpstreamAudio: true, rtt: 1.5,
                    loss: 9)),
            .connectionQuality(ConnectionQualityMessage()),
            .playTimeLeft(PlayTimeLeftMessage(timeLeft: 5, reason: "x")),
            .serverMessage(ServerTextMessage(text: "hello")),
            .fpsChange(FpsChangeMessage(fps: 60)),
            .controllerConnection(
                ControllerConnectionMessage(controllerId: -1, connected: true, controllerType: .vr2Sense)),
            .clientInfo(ClientInfoMessage(sessionKey: "k", gcmTag: 1, keyPosition: 2)),
            .videoCapture(VideoCaptureMessage(serverSide: true, idrPeriod: 30)),
            .audioCapture(AudioCaptureMessage(serverSide: false)),
            .idrRequest,
            .cryptoTrace(CryptoTraceMessage(sequence: 1, gcmTag: 2, keyPosition: 3)),
            .periodicTimestamp(PeriodicTimestampMessage(info: [1, 2], version: 3)),
            .serverSettings(ServerSettingsMessage(idrPeriod: 5, sendPeriodicTimestamp: true)),
            .directMessage(DirectMessagePayload(kind: 1, destination: 1000, data: [7])),
            .micConnection(MicConnectionMessage(controllerId: -2, connected: true, result: false)),
            .transportVersionRequest(TransportVersionRequest(supportedVersions: [7, 9, 12])),
            .transportVersionAck(TransportVersionAck(version: 9)),
            .unparsed(type: .log, payload: [1, 2, 3]),
            .unparsed(type: .debug, payload: []),
            .unparsed(type: .clientMetric, payload: [4]),
            .unknown(type: 99),
        ]
        for message in messages {
            let decoded = try StreamMessage.decode(message.encoded)
            #expect(decoded == message, "\(message)")
        }
        let types = messages.compactMap(\.type)
        for type in StreamMessageType.allCases { #expect(types.contains(type), "\(type)") }
    }

    @Test func defaultsAndOptionalsOfUnusedPayloads() throws {
        #expect(try VideoCaptureMessage(decoding: []) == VideoCaptureMessage())
        #expect(try ProbeBandwidth(decoding: ProbeBandwidth(id: 1, time: 2).encoded).loss == nil)
        #expect(try DirectMessagePayload(decoding: DirectMessagePayload(kind: 0, destination: 1001).encoded).data == nil)
        #expect(try PlayTimeLeftMessage(decoding: []) == PlayTimeLeftMessage())
        #expect(try ConnectionQualityMessage(decoding: []).rtt == nil)
        #expect(try TransportVersionAck(decoding: []).version == nil)
    }

    @Test func connectionQualityFromTheConsole() throws {
        var w = ProtobufWriter()
        w.varint(1, 15_000_000)
        w.float(3, 0.5)
        w.double(5, 2.5)
        w.varint(77, 1)  // unknown field
        let q = try ConnectionQualityMessage(decoding: w.encoded)
        #expect(q.targetBitrate == 15_000_000 && q.upstreamLoss == 0.5 && q.rtt == 2.5)
    }

    @Test func unknownControllerTypeAndWrapperTypes() {
        #expect(throws: ProtobufError.badValue("controllerType")) {
            try ControllerConnectionMessage(decoding: [0x18, 0x09])
        }
        #expect(try! StreamMessage.decode([0x08, 0x63]) == .unknown(type: 99))
        #expect(StreamMessage.unknown(type: 99).type == nil)
        // An unknown payload field next to a known type is ignored.
        #expect(try! StreamMessage.decode([0x08, 0x03, 0x78, 0x01]) == .heartbeat)
    }
}
