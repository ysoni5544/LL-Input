# Contributing to LL Input

Thanks for your interest! This is a small, focused project — a low-latency audio
passthrough for the macOS menu bar. Contributions of all sizes are welcome.

## Ground rules

- **Open an issue first** for anything beyond a small fix, so we can agree on the
  approach before you spend time on a PR.
- Keep the app **focused**: a menu-bar passthrough. Features that broaden it into
  a full mixer/DAW are probably out of scope — but ask, don't assume.
- Be kind. Assume good faith.

## Development setup

```bash
git clone https://github.com/<your-username>/ll-input.git
cd ll-input
./build.sh
open "dist/LL Input.app"
```

You need macOS 13+ and the Xcode command line tools. The build uses Swift Package
Manager; the only dependency is [swift-atomics](https://github.com/apple/swift-atomics).

For quick iteration you can `swift build`, but features that touch **Launch at
Login** (`SMAppService`) or **microphone permission** only behave correctly when
run from the assembled `.app` bundle (`./build.sh` → `open "dist/LL Input.app"`),
because they require a real, signed bundle.

## Testing changes by hand

There are no automated tests yet (audio I/O is hard to unit-test). When changing
the audio path, please verify at least:

- Start/stop from both the menu and right-click.
- Each engine (AVAudioEngine, Aggregate HAL, Dual-Device HAL) starts and produces
  audio.
- Output follows an **AirPods / headphone connect and disconnect** while running.
- Changing **buffer size** and **mode** while running doesn't crash or drop out
  permanently.
- The **idle timeout** countdown appears and stops listening on silence.

## Code style

- Match the surrounding style; keep it plain and readable.
- Realtime code (IOProcs, render callbacks, ring buffer) must stay
  **allocation-free and lock-free** — no Swift allocations, ARC traffic, or locks
  on the audio thread. Use the existing atomics pattern for cross-thread values.
- Prefer small, self-contained files per concern (see `ARCHITECTURE.md`).

## Submitting a PR

1. Fork, branch from `main`.
2. Make your change; keep the diff focused.
3. Describe what you changed and how you tested it.
4. Link the issue it addresses.

By contributing, you agree your contributions are licensed under the project's
[MIT license](LICENSE).
