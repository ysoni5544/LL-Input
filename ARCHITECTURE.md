# Architecture

LL Input is a menu-bar (`LSUIElement`) macOS app built with Swift Package Manager.
It has no dock icon and no main window; all UI is the status-bar menu plus a few
transient panels.

## Source map (`Sources/AudioPassthrough/`)

| File | Responsibility |
|------|----------------|
| `main.swift` | Entry point; creates the `NSApplication` and `AppDelegate`. |
| `AppDelegate.swift` | Owns the status item and menu, wires CoreAudio device listeners, drives start/stop, the idle-timeout poll, output-follow logic, and presents the panels. |
| `EngineCore.swift` | `PassthroughEngineProtocol` (the common engine surface), the `Preset`/mode definitions, and `EngineKind`. |
| `PassthroughEngine.swift` | AVAudioEngine-based engine (most compatible, highest latency). |
| `AggregateHALEngine.swift` | Lowest-latency engine: a private aggregate device + one HAL AudioUnit render callback. |
| `DualDeviceHALEngine.swift` | Separate input/output IOProcs bridged by a ring buffer, with drift handling. |
| `AggregateDevice.swift` | Creates/destroys the private CoreAudio aggregate device used by the aggregate engine. |
| `RingBuffer.swift` | Lock-free single-producer/single-consumer float ring buffer (uses swift-atomics). |
| `AudioDevices.swift` | Thin CoreAudio wrapper: enumerate devices, get/set default in/out, sample rate, buffer size, and register property listeners. |
| `AppSettings.swift` | Persisted settings (slider type, hidden menu items, engine) plus `MenuOption`/`SliderType`. |
| `SetupPanelController.swift` | Launch-time setup window: pick input/volume/output/timer/mode, then start or quit. |
| `SettingsPanelController.swift` | Settings window: engine, slider type, menu visibility, resets, launch-at-login. |
| `VolumeMenuItemView.swift` | Custom view embedding the volume slider directly in the menu. |
| `HelpWindow.swift` | The "How this app works" overview window. |
| `LoginItem.swift` | Launch-at-login registration via `SMAppService`. |

## Engine model

All three engines implement `PassthroughEngineProtocol`, so `AppDelegate` treats
them interchangeably and can hot-swap the active engine. The protocol exposes
`start`/`stop`/`refresh`, device/rate/buffer setters, a realtime `volume` gain, a
`currentPeakLevel` (for idle detection), and an `onInputLostWarning` callback.

- **AVAudioEngine**: connects `inputNode → mainMixer → outputNode`. The mixer
  carries the volume gain; a tap provides the peak level. Output follows the
  system default automatically.
- **Aggregate HAL**: builds a private aggregate device (input master, output
  drift-compensated), then runs one HAL output AudioUnit whose render callback
  pulls input and writes it to output in the same pass. Lowest latency, single
  clock.
- **Dual-Device HAL**: an input IOProc writes captured frames into the ring
  buffer; an output IOProc reads them out and applies gain. The devices run on
  independent clocks, so the ring holds a few buffers of slack.

## Realtime rules

Anything on the audio thread — the IOProcs, the AudioUnit render callback, and
the ring buffer — must be **allocation-free and lock-free**. Cross-thread scalars
(peak level, volume) are passed as bit-patterns through `ManagedAtomic`. Do not
introduce Swift allocations, ARC retain/release, logging, or locks in these paths.

## Device-change handling

`AudioDevices` registers CoreAudio property listeners for the default input, the
default output, and the device list. When the default **output** changes (e.g.
AirPods connect/disconnect), `AppDelegate.outputMayHaveChanged()` rebuilds the
pipeline via `engine.refresh()`. Because CoreAudio doesn't swap devices
atomically, `refresh()` validates the new device and retries briefly if it's
mid-transition. The pinned **input** is monitored too; if it disappears the app
warns and stops.

## Build

`build.sh` runs `swift build -c release`, assembles a `.app` bundle, copies the
menu-bar plug icons and (via `iconutil`) the app icon into `Contents/Resources`,
and ad-hoc code-signs it with the audio-input entitlement so microphone
permission and login-item registration work locally.
