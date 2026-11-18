import { Schema } from "effect"

/** A native command failed, or replied with something we couldn't decode. */
export class CoreError extends Schema.TaggedError<CoreError>()("CoreError", {
  command: Schema.String,
  message: Schema.String,
}) {}

/** localStorage is unavailable or rejected a write. */
export class StorageError extends Schema.TaggedError<StorageError>()("StorageError", {
  key: Schema.String,
  message: Schema.String,
}) {}

/** User input that can't be sent to the console as-is. */
export class ValidationError extends Schema.TaggedError<ValidationError>()("ValidationError", {
  message: Schema.String,
}) {}

export type AppError = CoreError | StorageError | ValidationError

export const errorMessage = (error: AppError): string => error.message
