# LL Input

A tiny, menu-bar-only macOS app that passes audio from an input device (typically a 3.5mm line-in) straight to your current output — a low-latency live monitor. Think of it as a lightweight, focused alternative to tools like LineIn or LadioCast, with selectable audio engines so you can trade latency against compatibility.

# Menu Bar
![LL Input menu bar](Screenshots/Menu%20Bar%20Dropdown.png)

# First Time Setup
![First Time Setup](Screenshots/Setup%20Screen.png)

# Settings
![Settings](Screenshots/Settings.png)

## Features

- **Live passthrough** from any input device to your current output.
- **Three selectable engines**, from most compatible to lowest latency:
  - **AVAudioEngine** — high-level graph. Most compatible, highest latency.
  - **Aggregate HAL** — wraps input + output in a private aggregate device driven by a single HAL render callback. One shared clock, no drift, lowest latency (LadioCast-class). Creates a hidden virtual device only while running.
  - **Dual-Device HAL** — separate input/output IOProcs bridged by a lock-free ring buffer with drift compensation. No virtual device; latency just above the aggregate.
- **One-click modes** — Game (48 kHz / 256), Stereo (auto-picks the best buffer), Ultra Latency (48 kHz / 64), and Custom (changes nothing).
- **Input volume** with two slider styles: bipolar (±dB, centered at 0) or linear (0–200%).
- **Follows device changes** — when the default output changes (AirPods connect/disconnect, headphones plugged in, etc.), the routing pipeline rebuilds automatically to follow it.
- **Idle timeout** — auto-stops after a chosen period of silence; the menu bar shows a live countdown.
- **Manual buffer size** control, and a one-click **Refresh** of the audio pipeline.
- **Setup panel** on launch to pick input, output, timer, and mode before starting.
- **Menu-bar icon** that reflects state — a solid plug when listening, an outline plug when idle.
- **Launch at login** (on by default; the setup window stays closed on login launches).

## Requirements

- macOS 13 (Ventura) or later
- Xcode command line tools (`xcode-select --install`)

## Download

Prebuilt app bundles are attached to each [release](../../releases). Download the
`.zip`, unzip it, and move **LL Input.app** to your Applications folder.

### First launch (unsigned build)

The prebuilt app is **ad-hoc signed, not notarized by Apple**, so macOS Gatekeeper
will warn the first time you open it. This is expected for an open-source build —
you only need to do this once.

**Recommended: right-click → Open**

1. In Finder, **right-click** (or Control-click) **LL Input.app**.
2. Choose **Open**.
3. In the dialog, click **Open** again.

macOS remembers your choice, so afterward it launches normally with a double-click.

**If macOS still blocks it** (newer versions may say the app "is damaged" or was
"not opened"), clear the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/LL Input.app"
```

Then open it normally. You can also allow it under **System Settings → Privacy &
Security** — after a blocked launch, an **"Open Anyway"** button appears there.

**Prefer no prompt at all?** Build it yourself — a locally built app doesn't get
quarantined:

```bash
./build.sh
open "dist/LL Input.app"
```

## Build & run

```bash
git clone https://github.com/<your-username>/ll-input.git
cd ll-input
./build.sh
open "dist/LL Input.app"
```

The first build fetches [swift-atomics](https://github.com/apple/swift-atomics) (used by the lock-free ring buffer). On first launch, grant **Microphone** access when prompted — a line-in is exposed to apps as an input/microphone, so this permission is required to read the incoming audio.

## Usage

- **Left-click** the menu-bar plug icon to open the menu.
- **Right-click** to start/stop listening instantly.
- Pick your **Input**, **Output**, and a **Mode**, then **Start Listening**.
- Open **Settings…** to choose the engine, volume slider type, which menu items to show, and Launch-at-Login.

## How it works

The app is a status-bar (`LSUIElement`) app with no dock icon. Each engine implements a common `PassthroughEngineProtocol`. The HAL engines run their audio in CoreAudio IOProcs / AudioUnit render callbacks and use a lock-free single-producer/single-consumer ring buffer to move samples between the input and output callbacks. Device changes are observed via CoreAudio property listeners, and the pipeline is torn down and rebuilt (with a short validate-and-retry) whenever the active output device changes.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a deeper tour of the source.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). Please open an issue to discuss larger changes before sending a PR.

## License

[MIT](LICENSE) © contributors. This project is not affiliated with Apple or Rogue Amoeba.
