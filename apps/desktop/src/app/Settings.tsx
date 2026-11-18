import { useId } from "react"
import { Label } from "@/components/ui/label"
import { NativeSelect, NativeSelectOption } from "@/components/ui/native-select"
import type { Settings } from "@/core/schema"
import { settingValue, withSetting, type SettingKey } from "./format"

interface SettingSelectProps {
  readonly label: string
  readonly setting: SettingKey
  readonly settings: Settings
  readonly onChange: (next: Settings) => void
  readonly options: readonly { readonly value: string; readonly label: string; readonly disabled?: boolean }[]
}

const SettingSelect = ({ label, setting, settings, onChange, options }: SettingSelectProps) => {
  const id = useId()
  return (
    <div className="flex flex-col gap-1">
      <Label htmlFor={id} className="text-xs text-muted-foreground">
        {label}
      </Label>
      <NativeSelect
        id={id}
        size="sm"
        value={settingValue(settings, setting)}
        onChange={(event) => { onChange(withSetting(settings, setting, event.target.value)); }}
      >
        {options.map((option) => (
          <NativeSelectOption key={option.value} value={option.value} disabled={option.disabled ?? false}>
            {option.label}
          </NativeSelectOption>
        ))}
      </NativeSelect>
    </div>
  )
}

interface SettingsProps {
  readonly settings: Settings
  readonly metalfxSupported: boolean
  readonly onChange: (next: Settings) => void
}

export const UpscalerSelect = ({ settings, metalfxSupported, onChange }: SettingsProps) => (
  <SettingSelect
    label="Upscaler"
    setting="upscaler"
    settings={settings}
    onChange={onChange}
    options={[
      { value: "metalfx", label: "MetalFX", disabled: !metalfxSupported },
      { value: "bilinear", label: "Bilinear" },
      { value: "compare", label: "Compare (split)", disabled: !metalfxSupported },
    ]}
  />
)

export const SettingsRow = (props: SettingsProps) => (
  <section aria-label="Stream settings" className="flex flex-wrap gap-3">
    <SettingSelect
      label="Resolution"
      setting="height"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "1080", label: "1080p" },
        { value: "720", label: "720p" },
        { value: "540", label: "540p" },
      ]}
    />
    <SettingSelect
      label="FPS"
      setting="fps"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "60", label: "60" },
        { value: "30", label: "30" },
      ]}
    />
    <SettingSelect
      label="Codec"
      setting="hevc"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "hevc", label: "HEVC" },
        { value: "h264", label: "H.264" },
      ]}
    />
    <UpscalerSelect {...props} />
  </section>
)
