import { Option } from "effect"
import { ChevronRight, CircleQuestionMark, ClipboardCopy, Code, FolderOpen, RotateCcw, Save, Trash2 } from "lucide-react"
import { useEffect, useId, useRef, useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Input } from "@/components/ui/input"
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { NativeSelect, NativeSelectOption } from "@/components/ui/native-select"
import { Slider } from "@/components/ui/slider"
import { Switch } from "@/components/ui/switch"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { SteadyWifiSection } from "./SteadyWifi"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { bitrates, defaultSettings, type AudioDevice, type Settings, type StreamOptions } from "@/core/schema"
import { toast } from "sonner"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import { allProfiles, isBuiltIn, isSaved, matchingProfile, profileSummary } from "./profiles"
import { ProfileSelect, useSavedProfiles, type ChangeSettings } from "./ProfileSelect"
import {
  bitrateLabel,
  pipelineStages,
  strengthLabel,
  type Capabilities,
  type Reconnecting,
  type SettingKey,
  type Stage,
  type StageId,
} from "./format"
import { useRun } from "./runtime"

const viewHints: Readonly<Record<Settings["view"], string>> = {
  original: "The stream as it arrives, without the steps below.",
  split: "Left half as it arrives, right half with the steps below.",
  enhanced: "The stream with the steps below.",
}

export type SettingsTab = "picture" | "stream" | "diagnostics"

const tabHints: Readonly<Record<SettingsTab, string>> = {
  picture: "Changes show on the video right away.",
  stream: "Changes apply the next time you connect.",
  diagnostics: "For tracking down problems and reporting bugs.",
}

/** Shown while streaming: stream settings only take effect on a new connection. */
export interface ReconnectState {
  /** Stream settings differ from the running session's. */
  readonly pending: boolean
  /** Restarting: to apply settings, or after the connection dropped. */
  readonly reconnecting: Reconnecting
  readonly onReconnect: () => void
  /** The stream options the stream runs with (those of a reconnect under way, once it's back): what switching
   * profile costs is measured against them. */
  readonly runsWith: StreamOptions
}

interface SettingsSheetProps {
  readonly open: boolean
  readonly onOpenChange: (open: boolean) => void
  readonly tab: SettingsTab
  readonly onTabChange: (tab: SettingsTab) => void
  readonly settings: Settings
  readonly capabilities: Capabilities
  /** Why the chosen upscaler isn't enlarging the picture right now (while streaming). */
  readonly upscaleIdle?: string
  readonly onChange: ChangeSettings
  /** Present while streaming. */
  readonly reconnect?: ReconnectState
}

const pictureKeys = [
  "upscaler",
  "sharpness",
  "deblock",
  "deband",
  "mlUpscale",
  "frameInterpolation",
  "view",
  "colorMatrix",
  "colorRange",
  "chroma",
  "accurateColor",
] as const satisfies readonly SettingKey[]
const streamKeys = ["height", "fps", "hevc", "hdr", "bitrate", "autoDowngrade", "audio"] as const satisfies readonly SettingKey[]

/** `settings` with the given keys back at their defaults. */
const reset = (settings: Settings, keys: readonly SettingKey[]): Settings =>
  keys.reduce<Settings>((next, key) => ({ ...next, [key]: defaultSettings[key] }), settings)

/** Settings panel over the video: picture settings apply live, stream settings on the next connection. */
export const SettingsSheet = (props: SettingsSheetProps) => {
  const { settings, onChange } = props
  const set = <K extends SettingKey>(key: K, value: Settings[K]) => { onChange({ ...settings, [key]: value }) }
  return (
    // Not modal: the video stays visible and live behind the panel while tuning.
    <Sheet open={props.open} onOpenChange={props.onOpenChange} modal={false}>
      <SheetContent
        side="right"
        onInteractOutside={(event) => { event.preventDefault() }}
        className="w-[23rem] gap-0 overflow-y-auto border-white/10 bg-glass p-0 backdrop-blur-2xl sm:max-w-[23rem]"
      >
        <SheetHeader className="px-5 pt-5 pb-3">
          <SheetTitle>Settings</SheetTitle>
          <SheetDescription>
            {tabHints[props.tab]}
          </SheetDescription>
        </SheetHeader>
        <ProfileBar settings={settings} running={props.reconnect?.runsWith} onChange={onChange} />
        {/* Above the tabs: a profile switch can need it from any tab. */}
        {props.reconnect?.pending === true && (
          <div className="px-5 pb-4">
            <ReconnectNotice {...props.reconnect} />
          </div>
        )}
        <Tabs
          value={props.tab}
          onValueChange={(tab) => { props.onTabChange(tab === "stream" || tab === "diagnostics" ? tab : "picture") }}
          className="gap-0"
        >
          <TabsList className="mx-5 grid grid-cols-3">
            <TabsTrigger value="picture">Picture</TabsTrigger>
            <TabsTrigger value="stream">Stream</TabsTrigger>
            <TabsTrigger value="diagnostics">Diagnostics</TabsTrigger>
          </TabsList>
          <TabsContent value="picture" className="flex flex-col gap-5 px-5 pt-5 pb-6">
            <PicturePanel settings={settings} capabilities={props.capabilities} upscaleIdle={props.upscaleIdle} set={set} />
            <Button variant="ghost" size="sm" className="self-start text-muted-foreground" onClick={() => { onChange(reset(settings, pictureKeys)) }}>
              <RotateCcw /> Reset picture
            </Button>
          </TabsContent>
          <TabsContent value="stream" className="flex flex-col gap-5 px-5 pt-5 pb-6">
            <StreamPanel settings={settings} set={set} />
            <Button variant="ghost" size="sm" className="self-start text-muted-foreground" onClick={() => { onChange(reset(settings, streamKeys)) }}>
              <RotateCcw /> Reset stream
            </Button>
          </TabsContent>
          <TabsContent value="diagnostics" className="flex flex-col gap-5 px-5 pt-5 pb-6">
            <DiagnosticsPanel settings={settings} set={set} />
          </TabsContent>
        </Tabs>
      </SheetContent>
    </Sheet>
  )
}

type Set = <K extends SettingKey>(key: K, value: Settings[K]) => void

// ---------- Profiles ----------

/** Settings profiles: pick one to apply its stream and picture settings, or save the current ones. */
const ProfileBar = ({ settings, running, onChange }: {
  readonly settings: Settings
  readonly running: StreamOptions | undefined
  readonly onChange: ChangeSettings
}) => {
  const run = useRun()
  const id = useId()
  const { saved, setSaved } = useSavedProfiles()
  /** The name being typed for a new profile; null when not saving. */
  const [naming, setNaming] = useState<string | null>(null)
  const nameInput = useRef<HTMLInputElement>(null)
  const selected = Option.getOrUndefined(matchingProfile(settings, allProfiles(saved)))
  /** Saving under a saved profile's name replaces that profile. */
  const replacing = naming !== null && isSaved(saved, naming)
  const save = (name: string) => {
    const verb = isSaved(saved, name) ? "Replaced" : "Saved"
    run(actions.saveProfile(name, settings), {
      onSuccess: (next) => {
        setSaved(next)
        setNaming(null)
        toast.success(`${verb} "${name.trim()}"`)
      },
    })
  }
  return (
    <div className="flex flex-col gap-1.5 px-5 pb-4">
      <label htmlFor={id} className="text-xs text-muted-foreground">Profile</label>
      <div className="flex gap-2">
        <ProfileSelect id={id} settings={settings} running={running} onChange={onChange} className="w-full" />
        {selected !== undefined && !isBuiltIn(selected) && (
          <Button
            variant="ghost"
            size="sm"
            aria-label={`Delete ${selected.name}`}
            onClick={() => { run(actions.deleteProfile(selected.name), { onSuccess: setSaved }) }}
          >
            <Trash2 />
          </Button>
        )}
        {naming === null && (
          <Button variant="secondary" size="sm" onClick={() => { setNaming("") }}>
            <Save /> Save as…
          </Button>
        )}
      </div>
      {naming !== null && (
        <form
          className="flex flex-col gap-2"
          onSubmit={(event) => {
            event.preventDefault()
            save(naming)
          }}
        >
          <div className="flex gap-2">
            <Input
              ref={nameInput}
              aria-label="Profile name"
              placeholder="Name, e.g. Living room TV"
              maxLength={40}
              autoFocus
              value={naming}
              onChange={(event) => { setNaming(event.target.value) }}
            />
            <Button type="submit" size="sm">{replacing ? "Replace" : "Save"}</Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => { setNaming(null) }}>Cancel</Button>
          </div>
          {saved.length > 0 && (
            <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Replace a saved profile">
              <span className="text-xs text-muted-foreground">Replace one:</span>
              {saved.map((p) => (
                <Button
                  key={p.name}
                  type="button"
                  variant={naming.trim() === p.name ? "secondary" : "outline"}
                  size="xs"
                  aria-pressed={naming.trim() === p.name}
                  onClick={() => {
                    setNaming(p.name)
                    nameInput.current?.focus()
                  }}
                >
                  {p.name}
                </Button>
              ))}
            </div>
          )}
          {replacing && (
            <p className="text-xs text-muted-foreground">Replaces "{naming.trim()}" with these settings.</p>
          )}
        </form>
      )}
      <p className="text-xs text-muted-foreground">
        {selected === undefined ? "Your own mix of settings. Save it to come back to it." : profileSummary(selected)}
      </p>
    </div>
  )
}

// ---------- Picture ----------

const PicturePanel = ({ settings, capabilities, upscaleIdle, set }: {
  readonly settings: Settings
  readonly capabilities: Capabilities
  readonly upscaleIdle: string | undefined
  readonly set: Set
}) => {
  const stages = pipelineStages(settings, capabilities, upscaleIdle)
  return (
    <>
      <Pipeline stages={stages} />
      <div className="flex flex-col gap-1.5">
        <Segmented
          label="View"
          value={settings.view}
          options={[
            { value: "original", label: "Original" },
            { value: "split", label: "Split" },
            { value: "enhanced", label: "Enhanced" },
          ]}
          onChange={(view) => { set("view", view) }}
        />
        <p className="text-xs text-muted-foreground">{viewHints[settings.view]}</p>
      </div>
      <SwitchRow
        label="Stats on screen"
        description="Shows the stats line at the top (frame rate, bitrate, ping, GPU time, lost frames, the images made in between, and why a step that’s on is idle) while playing, and keeps it there when the controls hide."
        checked={settings.showStats}
        onCheckedChange={(on) => { set("showStats", on) }}
      />
      <SwitchRow
        label="Frame interpolation"
        description={
          capabilities.interpolation
            ? "Makes images between the game’s own frames, one for each screen refresh: a 30 fps game looks like 60 on a 60 Hz screen and 120 on ProMotion (60 in HDR), even inside a 60 fps stream. Frames show about 40 ms later at 30 fps, so it suits slower games."
            : "Needs macOS 26 on a supported Mac."
        }
        checked={settings.frameInterpolation}
        disabled={!capabilities.interpolation}
        onCheckedChange={(on) => { set("frameInterpolation", on) }}
      />
      <Section stage={stages[0]} step={1} hint="Smooths compression artifacts before upscaling.">
        <StrengthSlider label="Blockiness" value={settings.deblock} onChange={(v) => { set("deblock", v) }} />
        <StrengthSlider label="Banding" value={settings.deband} onChange={(v) => { set("deband", v) }} />
      </Section>
      <Section stage={stages[1]} step={2} hint={capabilities.metalfx ? "Brings the stream up to your screen's resolution." : "MetalFX isn't available on this Mac."}>
        <Segmented
          label="Upscaler"
          value={settings.upscaler}
          onChange={(v) => { set("upscaler", v) }}
          options={[
            { value: "metalfx", label: "MetalFX", disabled: !capabilities.metalfx },
            { value: "bilinear", label: "Bilinear" },
          ]}
        />
        <SwitchRow
          label="ML upscaling first"
          description={
            capabilities.ml
              ? "Apple's neural upscaler adds detail before the step above, when the window is larger than the stream. It runs beside the display, so it never holds up a refresh, and adds about 6 ms of latency at 720p, up to 15 ms at 1080p."
              : "Needs macOS 26 on a supported Mac."
          }
          checked={settings.mlUpscale}
          disabled={!capabilities.ml}
          onCheckedChange={(on) => { set("mlUpscale", on) }}
        />
      </Section>
      <Section stage={stages[2]} step={3} hint="Restores edge contrast after upscaling, without halos.">
        <StrengthSlider label="Sharpness" value={settings.sharpness} onChange={(v) => { set("sharpness", v) }} />
      </Section>
      <Section stage={stages[3]} step={4} hint="Accurate matches the game's colors; Vivid uses your display's full gamut.">
        <Segmented
          label="Colors"
          value={settings.accurateColor ? "accurate" : "vivid"}
          onChange={(v) => { set("accurateColor", v === "accurate") }}
          options={[
            { value: "accurate", label: "Accurate" },
            { value: "vivid", label: "Vivid" },
          ]}
        />
        <Segmented
          label="Color detail"
          value={settings.chroma}
          onChange={(v) => { set("chroma", v) }}
          options={[
            { value: "bicubic", label: "Sharp" },
            { value: "bilinear", label: "Smooth" },
          ]}
        />
        <Collapsible>
          <CollapsibleTrigger className="group flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground">
            <ChevronRight className="size-3.5 transition-transform group-data-[state=open]:rotate-90" />
            For unusual streams
          </CollapsibleTrigger>
          <CollapsibleContent className="flex flex-col gap-3 pt-3">
            <Segmented
              label="Color matrix"
              value={settings.colorMatrix}
              onChange={(v) => { set("colorMatrix", v) }}
              options={[
                { value: "auto", label: "Auto" },
                { value: "bt709", label: "709" },
                { value: "bt601", label: "601" },
                { value: "bt2020", label: "2020" },
              ]}
            />
            <Segmented
              label="Color range"
              value={settings.colorRange}
              onChange={(v) => { set("colorRange", v) }}
              options={[
                { value: "auto", label: "Auto" },
                { value: "limited", label: "Limited" },
                { value: "full", label: "Full" },
              ]}
            />
          </CollapsibleContent>
        </Collapsible>
      </Section>
    </>
  )
}

const stageAnchor = (id: StageId): string => `picture-stage-${id}`

/** The picture pipeline in the order frames go through it; a stage jumps to its controls. */
const Pipeline = ({ stages }: { readonly stages: readonly Stage[] }) => (
  <nav aria-label="Picture pipeline">
    <ol className="grid grid-cols-4 gap-1.5">
      {stages.map((stage, index) => (
        <li key={stage.id} className="relative">
          <button
            type="button"
            onClick={() => document.getElementById(stageAnchor(stage.id))?.focus()}
            className="flex w-full flex-col items-start gap-0.5 rounded-md border border-white/10 bg-white/[0.03] px-2 pt-1.5 pb-2 text-left transition-colors hover:bg-white/[0.07] focus-visible:ring-2 focus-visible:ring-signal/60 focus-visible:outline-none"
          >
            <span className="text-[0.6875rem] text-muted-foreground">{stage.name}</span>
            <span
              key={stage.value}
              className={cn(
                "text-sm font-medium tabular-nums motion-safe:animate-in motion-safe:fade-in-0 motion-safe:slide-in-from-bottom-1 motion-safe:duration-200",
                stage.active ? "text-foreground" : "text-muted-foreground",
              )}
            >
              {stage.value}
            </span>
            {stage.note !== undefined && (
              <span className="text-[0.6875rem] text-muted-foreground">{stage.note}</span>
            )}
          </button>
          {/* The signal path: lit where this stage changes the picture. */}
          <span
            aria-hidden
            className={cn(
              "absolute inset-x-1 -bottom-1.5 h-0.5 rounded-full transition-colors duration-300",
              stage.active ? "bg-signal shadow-[0_0_8px_var(--signal)]" : "bg-white/15",
            )}
          />
          {index < stages.length - 1 && (
            <ChevronRight aria-hidden className="absolute top-1/2 -right-2 z-10 size-3 -translate-y-1/2 text-white/30" />
          )}
        </li>
      ))}
    </ol>
  </nav>
)

const Section = ({ stage, step, hint, children }: {
  readonly stage: Stage | undefined
  readonly step: number
  readonly hint: string
  readonly children: ReactNode
}) =>
  stage && (
    <section aria-labelledby={stageAnchor(stage.id)} className="flex flex-col gap-3">
      <div>
        <h3 id={stageAnchor(stage.id)} tabIndex={-1} className="flex items-baseline gap-2 text-sm font-medium outline-none focus-visible:text-signal">
          <span className={cn("text-xs tabular-nums", stage.active ? "text-signal" : "text-muted-foreground")}>{step}</span>
          {stage.name}
        </h3>
        <p className="mt-0.5 text-xs text-muted-foreground">{hint}</p>
      </div>
      {children}
    </section>
  )

// ---------- Stream ----------

const StreamPanel = ({ settings, set }: { readonly settings: Settings; readonly set: Set }) => {
  const bitrateIndex = Math.max(0, bitrates.indexOf(settings.bitrate))
  return (
    <>
      <SteadyWifiSection />
      <Segmented
        label="Resolution"
        value={String(settings.height)}
        onChange={(v) => { set("height", v === "720" ? 720 : v === "540" ? 540 : 1080) }}
        options={[
          { value: "1080", label: "1080p" },
          { value: "720", label: "720p" },
          { value: "540", label: "540p" },
        ]}
      />
      <Segmented
        label="Frame rate"
        value={String(settings.fps)}
        onChange={(v) => { set("fps", v === "30" ? 30 : 60) }}
        options={[
          { value: "60", label: "60 fps" },
          { value: "30", label: "30 fps" },
        ]}
      />
      <Segmented
        label="Codec"
        value={settings.hevc ? "hevc" : "h264"}
        onChange={(v) => { set("hevc", v === "hevc") }}
        options={[
          { value: "hevc", label: "HEVC" },
          { value: "h264", label: "H.264" },
        ]}
      />
      <SwitchRow
        label="HDR"
        description={
          settings.hevc
            ? "Brighter highlights and richer color in HDR games, on a Mac screen that shows HDR. Turn on HDR in the PS5's screen settings too."
            : "Needs the HEVC codec."
        }
        checked={settings.hevc && settings.hdr}
        disabled={!settings.hevc}
        onCheckedChange={(on) => { set("hdr", on) }}
      />
      <LabeledSlider
        label="Bitrate"
        valueLabel={bitrateLabel(settings.bitrate)}
        hint="Higher keeps more detail in motion. Auto lets the console decide."
        value={bitrateIndex}
        max={bitrates.length - 1}
        step={1}
        onChange={(i) => { set("bitrate", bitrates[i] ?? 0) }}
      />
      <SwitchRow
        label="Lower resolution when the network is slow"
        description="Keeps the stream smooth instead of stuttering."
        checked={settings.autoDowngrade}
        onCheckedChange={(on) => { set("autoDowngrade", on) }}
      />
      <SwitchRow label="Sound" checked={settings.audio} onCheckedChange={(on) => { set("audio", on) }} />
      <SoundOutput settings={settings} set={set} />
    </>
  )
}

// ---------- Sound output ----------

/** Volume and output device: unlike the rest of the Stream tab, these apply at once. */
const SoundOutput = ({ settings, set }: { readonly settings: Settings; readonly set: Set }) => {
  const run = useRun()
  const id = useId()
  const [devices, setDevices] = useState<readonly AudioDevice[]>([])
  useEffect(() => {
    run(actions.audioDevices, { onSuccess: setDevices })
  }, [run])
  // A device that's no longer connected plays through the system default; say so rather than hide it.
  const missing = settings.audioDevice !== "" && devices.length > 0 && !devices.some((d) => d.uid === settings.audioDevice)
  return (
    <fieldset disabled={!settings.audio} className="flex flex-col gap-4 disabled:opacity-50">
      <LabeledSlider
        label="Volume"
        valueLabel={`${String(Math.round(settings.volume * 100))}%`}
        value={settings.volume}
        max={1}
        step={0.05}
        onChange={(v) => { set("volume", v) }}
      />
      <div className="flex flex-col gap-1.5">
        <label htmlFor={id} className="text-xs text-muted-foreground">Output</label>
        <NativeSelect
          id={id}
          value={missing ? "" : settings.audioDevice}
          onChange={(event) => { set("audioDevice", event.target.value) }}
          className="w-full"
        >
          <NativeSelectOption value="">System default</NativeSelectOption>
          {devices.map((device) => (
            <NativeSelectOption key={device.uid} value={device.uid}>{device.name}</NativeSelectOption>
          ))}
        </NativeSelect>
        <p className="text-xs text-muted-foreground">
          {missing ? "The chosen output isn't connected, so sound plays through the system default." : "Volume and output change right away."}
        </p>
      </div>
    </fieldset>
  )
}

// ---------- Diagnostics ----------

const DiagnosticsPanel = ({ settings, set }: { readonly settings: Settings; readonly set: Set }) => {
  const run = useRun()
  const [build, setBuild] = useState<string | null>(null)
  useEffect(() => { run(actions.appInfo, { onSuccess: (info) => { setBuild(actions.buildLine(info)) } }) }, [run])
  return (
    <>
      {build !== null && (
        <p className="text-sm font-medium text-foreground select-text" aria-label="Version">{build}</p>
      )}
      <SwitchRow
        label="Detailed logs"
        description="Records much more about connections and the picture. Turn it off once the problem is found."
        checked={settings.detailedLogs}
        onCheckedChange={(on) => { set("detailedLogs", on) }}
      />
      <div className="flex flex-wrap gap-2">
        <Button
          variant="secondary"
          size="sm"
          onClick={() => {
            run(actions.copyDiagnostics(settings), {
              onSuccess: () => { toast.success("Diagnostics copied. Paste them into your bug report.") },
            })
          }}
        >
          <ClipboardCopy /> Copy diagnostics
        </Button>
        <Button variant="ghost" size="sm" onClick={() => { run(actions.openLogsFolder) }}>
          <FolderOpen /> Open logs folder
        </Button>
        <Button variant="ghost" size="sm" onClick={() => { run(actions.openHelp) }}>
          <CircleQuestionMark /> Help
        </Button>
      </div>
      <p className="text-xs text-muted-foreground">
        Logs never contain your PlayStation sign-in, pairing keys or account ID.
      </p>
      <div className="flex flex-col gap-2 border-t border-white/10 pt-4">
        <p className="text-xs text-muted-foreground">
          PlayFX is free software under the GNU AGPL-3.0, built on chiaki-ng. It isn't affiliated with Sony
          Interactive Entertainment. The licences of the third-party software it includes are in
          THIRD_PARTY_LICENSES, in the app's Contents/Resources folder.
        </p>
        <Button variant="ghost" size="sm" className="self-start" onClick={() => { run(actions.openSourceCode) }}>
          <Code /> Source code
        </Button>
      </div>
    </>
  )
}

const ReconnectNotice = ({ reconnecting, onReconnect }: ReconnectState) => (
  <div role="status" className="flex items-center justify-between gap-3 rounded-lg border border-signal/40 bg-signal/10 px-3 py-2.5">
    <p className="text-xs text-foreground">
      {reconnecting !== false ? "Reconnecting… the console needs a few seconds." : "Reconnect to use the new stream settings."}
    </p>
    <Button size="sm" onClick={onReconnect} disabled={reconnecting !== false} className="bg-signal text-black hover:bg-signal/90">
      Reconnect
    </Button>
  </div>
)

// ---------- Controls ----------

interface Option<V extends string> {
  readonly value: V
  readonly label: string
  readonly disabled?: boolean
}

/** A single choice among a few options. */
export const Segmented = <V extends string>({ label, value, options, onChange }: {
  readonly label: string
  readonly value: V
  readonly options: readonly Option<V>[]
  readonly onChange: (value: V) => void
}) => {
  const id = useId()
  return (
    <div className="flex flex-col gap-1.5">
      <span id={id} className="text-xs text-muted-foreground">{label}</span>
      <ToggleGroup
        type="single"
        aria-labelledby={id}
        value={value}
        onValueChange={(next) => {
          const option = options.find((o) => o.value === next)
          if (option) onChange(option.value) // clicking the selected option again would clear it
        }}
        spacing={0}
        className="w-full rounded-md border border-white/10 bg-black/20 p-0.5"
      >
        {options.map((option) => (
          <ToggleGroupItem
            key={option.value}
            value={option.value}
            disabled={option.disabled ?? false}
            size="sm"
            className="flex-1 rounded-[5px] text-xs text-muted-foreground data-[state=on]:bg-white/12 data-[state=on]:text-foreground"
          >
            {option.label}
          </ToggleGroupItem>
        ))}
      </ToggleGroup>
    </div>
  )
}

const LabeledSlider = ({ label, valueLabel, hint, value, max, step, onChange }: {
  readonly label: string
  readonly valueLabel: string
  readonly hint?: string
  readonly value: number
  readonly max: number
  readonly step: number
  readonly onChange: (value: number) => void
}) => (
  <div className="flex flex-col gap-2">
    <div className="flex items-baseline justify-between">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-xs font-medium tabular-nums">{valueLabel}</span>
    </div>
    <Slider
      aria-label={label}
      value={[value]}
      max={max}
      step={step}
      onValueChange={([v]) => { if (v !== undefined) onChange(v) }}
      className="[&_[data-slot=slider-range]]:bg-signal [&_[data-slot=slider-thumb]]:border-white/60"
    />
    {hint !== undefined && <p className="text-xs text-muted-foreground">{hint}</p>}
  </div>
)

/** A 0–1 strength shown as Off / 5–100%. */
const StrengthSlider = ({ label, value, onChange }: {
  readonly label: string
  readonly value: number
  readonly onChange: (value: number) => void
}) => (
  <LabeledSlider
    label={label}
    valueLabel={strengthLabel(value)}
    value={Math.round(value * 100)}
    max={100}
    step={5}
    onChange={(percent) => { onChange(percent / 100) }}
  />
)

const SwitchRow = ({ label, description, checked, disabled = false, onCheckedChange }: {
  readonly label: string
  readonly description?: string
  readonly checked: boolean
  readonly disabled?: boolean
  readonly onCheckedChange: (checked: boolean) => void
}) => {
  const id = useId()
  return (
    <div className="flex items-start justify-between gap-4">
      <label htmlFor={id} className="flex flex-col gap-0.5">
        <span className="text-sm">{label}</span>
        {description !== undefined && <span className="text-xs text-muted-foreground">{description}</span>}
      </label>
      <Switch id={id} checked={checked} disabled={disabled} onCheckedChange={onCheckedChange} className="mt-0.5 data-[state=checked]:bg-signal" />
    </div>
  )
}
