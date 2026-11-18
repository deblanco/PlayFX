import { describe, expect, it } from "@effect/vitest"
import { Exit, Option, Schema } from "effect"
import {
  Credentials,
  defaultSettings,
  DiscoveredConsoles,
  isAccountId,
  isPin,
  PairedConsoles,
  PsnAccountEvent,
  RendererStatus,
  Settings,
  StartReply,
  StreamEvent,
} from "./schema"

const decodes = (schema: Schema.ConstraintDecoder<unknown>, input: unknown) =>
  Exit.isSuccess(Schema.decodeUnknownExit(schema)(input))

// Shapes below mirror what StreamCore (MacOSBridge.swift / Console.swift) and the Tauri host
// (src-tauri/src/lib.rs) actually send.
const ps5 = {
  address: "192.168.0.40",
  name: "PS5-123",
  hostId: "A1B2C3D4E5F6",
  systemVersion: "09060008",
  runningApp: "Astro's Playroom",
  ps5: true,
  state: "ready",
}

const credentials = {
  address: "192.168.0.40",
  ps5: true,
  nickname: "PS5-123",
  mac: "a1b2c3d4e5f6",
  registKey: "AAAAAAAAAAAAAAAAAAAAAA==",
  rpKey: "AAAAAAAAAAAAAAAAAAAAAA==",
  accountId: "AAAAAAAAAAA=",
}

describe("DiscoveredConsoles", () => {
  it("decodes the discover reply, with and without a running app", () => {
    const { runningApp: _omitted, ...standby } = { ...ps5, state: "standby" }
    const decoded = Schema.decodeUnknownSync(DiscoveredConsoles)([ps5, standby, { ...ps5, state: "unknown" }])
    expect(decoded).toHaveLength(3)
    expect(decoded[0]?.runningApp).toBe("Astro's Playroom")
    expect(decoded[1]).not.toHaveProperty("runningApp")
  })

  it("decodes an empty discovery", () => {
    expect(Schema.decodeUnknownSync(DiscoveredConsoles)([])).toEqual([])
  })

  it("rejects unknown states, missing fields and wrong types", () => {
    expect(decodes(DiscoveredConsoles, [{ ...ps5, state: "busy" }])).toBe(false)
    const { hostId: _missing, ...noHostId } = ps5
    expect(decodes(DiscoveredConsoles, [noHostId])).toBe(false)
    expect(decodes(DiscoveredConsoles, [{ ...ps5, ps5: "true" }])).toBe(false)
    // Swift omits nil optionals; an explicit null is not what the native side sends.
    expect(decodes(DiscoveredConsoles, [{ ...ps5, runningApp: null }])).toBe(false)
    expect(decodes(DiscoveredConsoles, { error: "socket failed" })).toBe(false)
    expect(decodes(DiscoveredConsoles, null)).toBe(false)
  })
})

describe("Credentials", () => {
  it("decodes the register reply", () => {
    expect(Schema.decodeUnknownSync(Credentials)(credentials)).toEqual(credentials)
  })

  it("rejects the native error shape and partial credentials", () => {
    expect(decodes(Credentials, { error: "Registration failed" })).toBe(false)
    const { rpKey: _missing, ...partial } = credentials
    expect(decodes(Credentials, partial)).toBe(false)
  })
})

describe("PairedConsoles", () => {
  it("decodes a record of paired consoles keyed by host ID", () => {
    const value = { A1B2: { hostId: "A1B2", name: "Living room", credentials } }
    expect(Schema.decodeUnknownSync(PairedConsoles)(value)).toEqual(value)
    expect(Schema.decodeUnknownSync(PairedConsoles)({})).toEqual({})
  })

  it("rejects a record holding a malformed console", () => {
    expect(decodes(PairedConsoles, { A1B2: { hostId: "A1B2", name: "x" } })).toBe(false)
    expect(decodes(PairedConsoles, [])).toBe(false)
  })
})

describe("Settings", () => {
  it("accepts the defaults", () => {
    expect(Schema.decodeUnknownSync(Settings)(defaultSettings)).toEqual(defaultSettings)
  })

  it("accepts every supported resolution, frame rate and upscaler", () => {
    for (const height of [540, 720, 1080])
      for (const fps of [30, 60])
        for (const upscaler of ["metalfx", "bilinear"])
          expect(decodes(Settings, { height, fps, hevc: false, upscaler })).toBe(true)
  })

  it("rejects unsupported values", () => {
    expect(decodes(Settings, { ...defaultSettings, height: 1440 })).toBe(false)
    expect(decodes(Settings, { ...defaultSettings, fps: 120 })).toBe(false)
    expect(decodes(Settings, { ...defaultSettings, height: "1080" })).toBe(false)
    expect(decodes(Settings, { ...defaultSettings, upscaler: "none" })).toBe(false)
  })
})

describe("StreamEvent", () => {
  it("decodes every event the session emits", () => {
    const events = [
      { type: "connected" },
      { type: "quit", reason: "Stopped", error: false },
      { type: "quit", reason: "Connection lost", error: true },
      { type: "loginPin", incorrect: false },
      { type: "nickname", name: "PS5-123" },
    ]
    for (const event of events) expect(Schema.decodeUnknownSync(StreamEvent)(event)).toEqual(event)
  })

  it("rejects unknown types and incomplete events", () => {
    expect(decodes(StreamEvent, { type: "paused" })).toBe(false)
    expect(decodes(StreamEvent, { type: "quit", reason: "x" })).toBe(false)
    expect(decodes(StreamEvent, { type: "loginPin" })).toBe(false)
    expect(decodes(StreamEvent, "connected")).toBe(false)
  })
})

describe("PsnAccountEvent", () => {
  it("decodes the success and failure shapes", () => {
    expect(Schema.decodeUnknownSync(PsnAccountEvent)({ accountId: "AAAAAAAAAAA=" })).toEqual({
      accountId: "AAAAAAAAAAA=",
    })
    expect(Schema.decodeUnknownSync(PsnAccountEvent)({ error: "denied" })).toEqual({ error: "denied" })
  })

  it("rejects anything else", () => {
    expect(decodes(PsnAccountEvent, {})).toBe(false)
    expect(decodes(PsnAccountEvent, { accountId: 42 })).toBe(false)
  })
})

describe("RendererStatus", () => {
  it("decodes an idle renderer", () => {
    const idle = { metalfxSupported: true, activeMode: "none", gpuMs: 0, stream: { active: false } }
    expect(Schema.decodeUnknownSync(RendererStatus)(idle)).toEqual(idle)
  })

  it("decodes a streaming renderer with stats", () => {
    const streaming = {
      metalfxSupported: false,
      activeMode: "bilinear",
      gpuMs: 1.42,
      stream: { active: true, framesDecoded: 1200, decodeErrors: 0, framesLost: 3, width: 1920, height: 1080, bytesReceived: 4096 },
    }
    expect(Schema.decodeUnknownSync(RendererStatus)(streaming)).toEqual(streaming)
  })

  it("rejects unknown modes and a missing stream (the host sends null when stats don't parse)", () => {
    expect(decodes(RendererStatus, { metalfxSupported: true, activeMode: "fsr", stream: { active: false } })).toBe(false)
    expect(decodes(RendererStatus, { metalfxSupported: true, activeMode: "none", stream: null })).toBe(false)
  })
})

describe("StartReply", () => {
  it("accepts only ok: true", () => {
    expect(decodes(StartReply, { ok: true })).toBe(true)
    expect(decodes(StartReply, { ok: false })).toBe(false)
    expect(decodes(StartReply, { error: "busy" })).toBe(false)
  })
})

describe("isAccountId", () => {
  it("accepts 8 bytes of base64", () => {
    expect(isAccountId("AAAAAAAAAAA=")).toBe(true)
    expect(isAccountId(btoa(String.fromCharCode(0xff, 0xfe, 0x01, 0x80, 0x7f, 0x00, 0x2b, 0x2f)))).toBe(true)
    expect(isAccountId("ab+/CD09xyZ=")).toBe(true)
  })

  it("rejects other lengths, alphabets and formats", () => {
    expect(isAccountId("")).toBe(false)
    expect(isAccountId("AAAAAAAAAAAA")).toBe(false) // 9 bytes, no padding
    expect(isAccountId("AAAAAAAAAA==")).toBe(false) // 7 bytes
    expect(isAccountId("AAAAAAAAAAAAAAAAAAAAAA==")).toBe(false) // 16 bytes
    expect(isAccountId("ab-_CD09xyZ=")).toBe(false) // URL-safe alphabet
    expect(isAccountId(" AAAAAAAAAAA=")).toBe(false)
    expect(isAccountId("AAAAAAAAAAA=\n")).toBe(false)
    expect(isAccountId("1234567890123456789")).toBe(false) // decimal account number
  })
})

describe("isPin", () => {
  it("accepts exactly 8 ASCII digits", () => {
    expect(isPin("12345678")).toBe(true)
    expect(isPin("00000000")).toBe(true)
  })

  it("rejects anything else", () => {
    expect(isPin("")).toBe(false)
    expect(isPin("1234567")).toBe(false)
    expect(isPin("123456789")).toBe(false)
    expect(isPin("1234 5678")).toBe(false)
    expect(isPin("1234-5678")).toBe(false)
    expect(isPin("abcdefgh")).toBe(false)
    expect(isPin("１２３４５６７８")).toBe(false) // full-width digits
    expect(isPin("12345678\n")).toBe(false)
  })
})

describe("decodeUnknownOption on a union", () => {
  it("is Some only for a valid event", () => {
    expect(Option.isSome(Schema.decodeUnknownOption(StreamEvent)({ type: "connected" }))).toBe(true)
    expect(Option.isSome(Schema.decodeUnknownOption(StreamEvent)({ type: "nope" }))).toBe(false)
  })
})
