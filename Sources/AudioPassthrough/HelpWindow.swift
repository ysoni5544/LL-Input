import Cocoa

/// A simple scrollable window that explains every menu choice and app feature.
/// Shown at startup and via "How This App Works…" in the menu.
enum HelpWindow {

    static func make() -> NSWindow {
        let width: CGFloat = 560
        let height: CGFloat = 620

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "LL Input — Overview"
        win.center()

        let scroll = NSScrollView(frame: win.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textStorage?.setAttributedString(bodyText())
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        win.contentView = scroll
        return win
    }

    private static func bodyText() -> NSAttributedString {
        let s = NSMutableAttributedString()

        func h(_ t: String) {
            s.append(NSAttributedString(string: t + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor
            ]))
        }
        func p(_ t: String) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 8
            para.lineSpacing = 2
            s.append(NSAttributedString(string: t + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para
            ]))
        }

        h("What this app does")
        p("It takes audio coming into your Mac (your 3.5mm line-in) and plays it out of your speakers or headphones in real time — a live monitor / passthrough. It lives in the menu bar only; there's no dock icon or window besides this one.")

        h("Menu bar icon")
        p("Left-click opens the menu. Right-click starts or stops listening instantly, without opening the menu.")

        h("Start / Stop Listening (⌘L)")
        p("Begins or ends the passthrough. The line under it shows the live output device, sample rate, and buffer size while running.")

        h("Input ▸")
        p("Pick which capture device to listen to — normally your 3.5mm line-in. The choice is pinned: if the system input changes elsewhere, the app tries to switch back, and warns you if it can't.")

        h("Output ▸")
        p("Pick where sound plays. Selecting one here sets it as the current output; the passthrough follows the change immediately.")

        h("Settings… (⌘,)")
        p("Opens the settings window. There you choose the volume slider type (Type A centered at 0 dB, or Type B 0–200%), pick the audio engine, show or hide individual menu items, and reset menu visibility or all settings to defaults. The engine options are AVAudioEngine (most compatible, highest latency), Aggregate HAL (one shared clock, lowest latency), and Dual-Device HAL (separate callbacks bridged by a buffer, very low latency, no virtual device).")

        h("Modes ▸")
        p("One-click tuning presets, next to Input and Output. Game Mode (48 kHz, 256-frame buffer) is a balanced low-latency setting and is selected by default. Stereo Mode picks the best-supported buffer for your device. Ultra Latency Mode (48 kHz, 64-frame buffer) is the lowest latency the hardware allows — use it if your setup can keep up without dropouts.")

        h("Buffer Size ▸")
        p("The number of frames processed per cycle. Smaller = lower latency but more risk of dropouts; larger = safer but more delay. If you hear crackling, step the buffer up.")

        h("Idle Timeout ▸")
        p("Automatically stops listening after a chosen period of silence on the input; the default is 5 minutes. While it's counting down, the menu bar shows the remaining time in a large font instead of the app icon, and it resets to the full duration the moment any sound is detected. The app icon returns whenever the countdown isn't active. Pick a duration, or Off to disable.")

        h("Setup panel")
        p("On every launch a setup window opens where you pick input, input volume, output, idle timer, and mode, then press Start Listening to begin (this closes the window), or Close Application to quit. Nothing starts on its own. It reopens if you launch or click the app again while it's running. Your input choice, volume, and idle-timeout are remembered between runs.")

        h("Refresh Audio Routing (⌘R)")
        p("Tears down and rebuilds the audio pipeline with the current settings. Use it after changing devices or settings, or to clear a glitch.")

        h("How This App Works… (⌘?)")
        p("Reopens this overview at any time.")

        h("Quit (⌘Q)")
        p("Stops the passthrough and exits.")

        h("First launch")
        p("macOS asks for Microphone permission because a line-in is exposed to apps as an input/mic. Grant it, or the app can't read the incoming audio.")

        return s
    }
}
