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
    ]}
  />
)

export const PictureSelects = ({ settings, onChange }: Omit<SettingsProps, "metalfxSupported">) => (
  <>
    <SettingSelect
      label="Sharpness"
      setting="sharpness"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "0", label: "Off" },
        { value: "0.15", label: "Low" },
        { value: "0.3", label: "Medium" },
        { value: "0.6", label: "High" },
        { value: "1", label: "Max" },
      ]}
    />
    <SettingSelect
      label="Compare"
      setting="compare"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "off", label: "Off" },
        { value: "on", label: "Split screen" },
      ]}
    />
    <SettingSelect
      label="Colors"
      setting="accurateColor"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "on", label: "Accurate" },
        { value: "off", label: "Vivid" },
      ]}
    />
    <SettingSelect
      label="Color detail"
      setting="chroma"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "bicubic", label: "Sharp" },
        { value: "bilinear", label: "Smooth" },
      ]}
    />
    <SettingSelect
      label="Color matrix"
      setting="colorMatrix"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "auto", label: "Automatic" },
        { value: "bt709", label: "BT.709 (HD)" },
        { value: "bt601", label: "BT.601 (SD)" },
        { value: "bt2020", label: "BT.2020 (UHD)" },
      ]}
    />
    <SettingSelect
      label="Color range"
      setting="colorRange"
      settings={settings}
      onChange={onChange}
      options={[
        { value: "auto", label: "Automatic" },
        { value: "limited", label: "Limited (16–235)" },
        { value: "full", label: "Full (0–255)" },
      ]}
    />
  </>
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
    <SettingSelect
      label="Bitrate"
      setting="bitrate"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "0", label: "Auto" },
        ...[10, 15, 20, 30, 40, 50].map((mbps) => ({ value: String(mbps * 1000), label: `${mbps} Mbps` })),
      ]}
    />
    <SettingSelect
      label="When the network is slow"
      setting="autoDowngrade"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "on", label: "Lower resolution" },
        { value: "off", label: "Keep resolution" },
      ]}
    />
    <SettingSelect
      label="Audio"
      setting="audio"
      settings={props.settings}
      onChange={props.onChange}
      options={[
        { value: "on", label: "On" },
        { value: "off", label: "Off" },
      ]}
    />
    <UpscalerSelect {...props} />
    <PictureSelects settings={props.settings} onChange={props.onChange} />
  </section>
)
