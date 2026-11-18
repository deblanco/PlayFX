import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { CoreError, errorMessage, StorageError, ValidationError } from "./errors"

describe("errors", () => {
  it("are tagged and carry their fields", () => {
    const core = new CoreError({ command: "discover", message: "socket failed" })
    expect(core._tag).toBe("CoreError")
    expect(core.command).toBe("discover")

    const storage = new StorageError({ key: "psrp.settings", message: "quota" })
    expect(storage._tag).toBe("StorageError")
    expect(storage.key).toBe("psrp.settings")

    expect(new ValidationError({ message: "bad pin" })._tag).toBe("ValidationError")
  })

  it("errorMessage returns the human-readable message of any app error", () => {
    expect(errorMessage(new CoreError({ command: "x", message: "a" }))).toBe("a")
    expect(errorMessage(new StorageError({ key: "k", message: "b" }))).toBe("b")
    expect(errorMessage(new ValidationError({ message: "c" }))).toBe("c")
  })

  it.effect("can be yielded as failures and caught by tag", () =>
    Effect.gen(function* () {
      const recovered = yield* Effect.fail(new ValidationError({ message: "bad pin" })).pipe(
        Effect.catchTag("ValidationError", (e) => Effect.succeed(`caught: ${e.message}`)),
      )
      expect(recovered).toBe("caught: bad pin")
    }),
  )
})
