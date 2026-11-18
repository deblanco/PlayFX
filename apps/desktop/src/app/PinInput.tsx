import { REGEXP_ONLY_DIGITS } from "input-otp"
import { InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot } from "@/components/ui/input-otp"

// Adapted from @shadcn-studio input-otp-08 (grouped OTP): the 8-digit pairing PIN as two groups of 4.

interface PinInputProps {
  readonly id: string
  readonly value: string
  readonly onChange: (value: string) => void
  readonly disabled?: boolean
}

export const PinInput = ({ id, value, onChange, disabled = false }: PinInputProps) => (
  <InputOTP
    id={id}
    maxLength={8}
    pattern={REGEXP_ONLY_DIGITS}
    inputMode="numeric"
    value={value}
    onChange={onChange}
    disabled={disabled}
    aria-label="Pairing PIN"
  >
    <InputOTPGroup>
      {[0, 1, 2, 3].map((index) => (
        <InputOTPSlot key={index} index={index} />
      ))}
    </InputOTPGroup>
    <InputOTPSeparator />
    <InputOTPGroup>
      {[4, 5, 6, 7].map((index) => (
        <InputOTPSlot key={index} index={index} />
      ))}
    </InputOTPGroup>
  </InputOTP>
)
