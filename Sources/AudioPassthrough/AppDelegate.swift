import Cocoa
import AVFoundation
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var engine: PassthroughEngineProtocol = DualDeviceHALEngine()
    private var engineKind: EngineKind = .dualDeviceHAL
    private var settingsPanel: SettingsPanelController?
    private let listenerQueue = DispatchQueue(label: "audio.passthrough.listeners")

    private var inputListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    private var selectedInputID: AudioDeviceID?
    private var lastKnownOutputID: AudioDeviceID = 0
    private var activeMode: Preset?
    private var inputVolume: Float = 1.0  // display fraction: 1.0 == slider's 100%
    private weak var volumeMenuView: VolumeMenuItemView?

    /// Convert the displayed volume fraction (slider's own scale, 1.0 = 100%)
    /// into the actual linear gain, scaled by the master limit and capped at the
    /// boost ceiling. The menu/setup sliders show 0–100% (or 0–200% with boost),
    /// but their 100% maps to the master limit.
    /// Convert the displayed volume fraction (slider's own scale, 1.0 = 100%)
    /// into the actual linear gain, scaled by the master limit and capped at the
    /// boost ceiling.
    private func actualGain(forDisplay display: Float) -> Float {
        let cap = AppSettings.shared.maxGain
        let limit = min(AppSettings.shared.masterLimit, cap)
        return min(display * limit, cap)
    }

    /// Push the current display volume to the engine as real gain.
    private func applyVolumeToEngine() {
        engine.volume = actualGain(forDisplay: inputVolume)
    }

    // Idle-timeout: stop listening after this many seconds of silence. 0 = off.
    // Defaults to 5 minutes; overridden by any saved value on launch.
    private var idleTimeoutSeconds: Int = 300
    private var idlePollTimer: Timer?
    private var silentSince: Date?
    private let silenceThreshold: Float = 0.003 // ~ -50 dBFS
    private let silenceGracePeriod: TimeInterval = 5 // wait before countdown begins
    private var helpWindow: NSWindow?
    private var setupPanel: SetupPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestMicPermission()

        restoreSettings()

        // Enable "Launch at Login" by default on first run.
        LoginItem.applyDefaultIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(active: false)
        // Handle clicks ourselves so right-click can toggle listening while
        // left-click opens the menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu = NSMenu()
        rebuildMenu()

        wireEngineCallbacks()

        // Listen for default-input changes so we can restore/warn.
        inputListener = AudioDevices.addDefaultDeviceListener(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async { self?.engine.handleInputChanged() }
            }

        // When the default output changes (System Settings, headphone plug,
        // AirPods connect/disconnect, another app), rebuild routing to follow it.
        outputListener = AudioDevices.addDefaultDeviceListener(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async { self?.outputMayHaveChanged() }
            }

        // Device add/remove (e.g. AirPods power on/off). macOS may reassign the
        // default output slightly after the removal event, so re-check on a
        // short delay in addition to the immediate check.
        deviceListListener = AudioDevices.addDefaultDeviceListener(
            selector: kAudioHardwarePropertyDevices,
            queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.outputMayHaveChanged()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.outputMayHaveChanged()
                    }
                }
            }

        // Turn on Game Mode by default (the setup panel can change it).
        applyMode(.game)

        // On login launch, show setup only if the user opted in; otherwise start
        // quietly. On a normal (user-initiated) launch, always show setup.
        let isLogin = launchedAtLogin(notification)
        if isLogin && !AppSettings.shared.showSetupAtLogin {
            // Auto-start with the remembered input, if there is one.
            if selectedInputID != nil, AudioDevices.defaultOutput() != 0 {
                restart()
                if engine.isRunning { startIdlePollIfNeeded() }
                updateStatusIcon(active: engine.isRunning)
                rebuildMenu()
            }
        } else {
            showSetupPanel()
        }
    }

    /// True when macOS launched the app automatically as a login item, rather
    /// than the user opening it. Login-item launches are not the "default"
    /// (user-initiated) launch, so this key is false/absent for them.
    private func launchedAtLogin(_ notification: Notification) -> Bool {
        if let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool {
            return !isDefault
        }
        return false
    }

    /// Fired when the app is re-opened while already running (e.g. clicking its
    /// icon in Launchpad/Finder). A menu-bar accessory isn't relaunched, so this
    /// is where we reopen the setup panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetupPanel()
        return true
    }

    // MARK: - Persistence

    private func restoreSettings() {
        let d = UserDefaults.standard
        // Restore idle timeout only if one was saved; otherwise keep the 5-min default.
        if d.object(forKey: "idleTimeoutSeconds") != nil {
            idleTimeoutSeconds = d.integer(forKey: "idleTimeoutSeconds")
        }

        // Restore the selected input by UID (IDs aren't stable across reboots).
        if let uid = d.string(forKey: "selectedInputUID"),
           let dev = AudioDevices.inputs().first(where: { $0.uid == uid }) {
            selectedInputID = dev.id
        }

        // Restore input volume.
        if d.object(forKey: "inputVolume") != nil {
            inputVolume = d.float(forKey: "inputVolume")
        }

        // Restore engine from settings (create the matching instance).
        let savedKind = AppSettings.shared.engineKind
        if savedKind != engineKind {
            engineKind = savedKind
            switch savedKind {
            case .avAudioEngine: engine = PassthroughEngine()
            case .aggregateHAL:  engine = AggregateHALEngine()
            case .dualDeviceHAL: engine = DualDeviceHALEngine()
            }
        }
        applyVolumeToEngine()
    }

    private func saveSelectedInput() {
        if let id = selectedInputID, let dev = AudioDevices.device(for: id) {
            UserDefaults.standard.set(dev.uid, forKey: "selectedInputUID")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        if let b = inputListener {
            AudioDevices.removeDefaultDeviceListener(
                selector: kAudioHardwarePropertyDefaultInputDevice, queue: listenerQueue, block: b)
        }
        if let b = outputListener {
            AudioDevices.removeDefaultDeviceListener(
                selector: kAudioHardwarePropertyDefaultOutputDevice, queue: listenerQueue, block: b)
        }
        if let b = deviceListListener {
            AudioDevices.removeDefaultDeviceListener(
                selector: kAudioHardwarePropertyDevices, queue: listenerQueue, block: b)
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        let currentOut = AudioDevices.defaultOutput()
        let settings = AppSettings.shared

        // ---- Status header ----
        let header = NSMenuItem(title: engine.isRunning ? "● Listening" : "○ Idle",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // ---- Start / Stop at top (never hideable) ----
        let toggle = NSMenuItem(
            title: engine.isRunning ? "Stop Listening" : "Start Listening",
            action: #selector(togglePassthrough), keyEquivalent: "l")
        toggle.target = self
        toggle.isEnabled = (selectedInputID != nil)
        menu.addItem(toggle)

        if engine.isRunning {
            let out = AudioDevices.device(for: currentOut)?.name ?? "Unknown"
            let rate = AudioDevices.nominalSampleRate(currentOut)
            let buf = AudioDevices.bufferFrameSize(currentOut)
            let status = NSMenuItem(title: "▶︎ \(out) · \(Int(rate))Hz · \(buf)f",
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        // ---- Input dropdown ----
        if !settings.isHidden(.input) {
            let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
            let inputMenu = NSMenu()
            let inputs = AudioDevices.inputs()
            if inputs.isEmpty {
                let none = NSMenuItem(title: "No inputs found", action: nil, keyEquivalent: "")
                none.isEnabled = false
                inputMenu.addItem(none)
            } else {
                for dev in inputs {
                    let mi = NSMenuItem(title: dev.name, action: #selector(selectInput(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = dev.id
                    mi.state = (dev.id == selectedInputID) ? .on : .off
                    inputMenu.addItem(mi)
                }
            }
            if let sel = selectedInputID, let dev = AudioDevices.device(for: sel) {
                inputItem.title = "Input: \(dev.name)"
            }
            inputItem.submenu = inputMenu
            menu.addItem(inputItem)
        }

        // ---- Input volume slider (inline) ----
        if !settings.isHidden(.volume) {
            let volItem = NSMenuItem()
            let view = VolumeMenuItemView(gain: inputVolume, sliderType: settings.sliderType,
                                          maxDisplay: settings.maxGain)
            view.onChange = { [weak self] g in
                guard let self = self else { return }
                self.inputVolume = g
                self.applyVolumeToEngine()
                UserDefaults.standard.set(g, forKey: "inputVolume")
            }
            volItem.view = view
            volumeMenuView = view
            menu.addItem(volItem)
        }

        // ---- Output dropdown ----
        if !settings.isHidden(.output) {
            let outputItem = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
            let outputMenu = NSMenu()
            for dev in AudioDevices.outputs() {
                let mi = NSMenuItem(title: dev.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = dev.id
                mi.state = (dev.id == currentOut) ? .on : .off
                outputMenu.addItem(mi)
            }
            if let dev = AudioDevices.device(for: currentOut) {
                outputItem.title = "Output: \(dev.name)"
            }
            outputItem.submenu = outputMenu
            menu.addItem(outputItem)
        }

        // ---- Modes dropdown ----
        if !settings.isHidden(.modes) {
            let modesItem = NSMenuItem(title: activeMode != nil ? "Modes: \(activeMode!.title)" : "Modes",
                                       action: nil, keyEquivalent: "")
            let modesMenu = NSMenu()
            let modeList: [(Preset, String)] = [
                (.game, "g"), (.stereo, ""), (.ultra, "u"), (.custom, ""),
            ]
            for (mode, key) in modeList {
                let mi = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: key)
                mi.target = self
                mi.representedObject = modeRaw(mode)
                mi.state = (mode == activeMode) ? .on : .off
                modesMenu.addItem(mi)
            }
            modesItem.submenu = modesMenu
            menu.addItem(modesItem)
        }

        // ---- Buffer size submenu ----
        if !settings.isHidden(.buffer) {
            menu.addItem(.separator())
            let bufItem = NSMenuItem(title: "Buffer Size", action: nil, keyEquivalent: "")
            let bufMenu = NSMenu()
            let bufDeviceID = selectedInputID ?? currentOut
            let currentBuf = AudioDevices.bufferFrameSize(bufDeviceID)
            let range = AudioDevices.bufferFrameSizeRange(bufDeviceID)
            for f in [UInt32(32), 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096] {
                if let range = range, !range.contains(f) { continue }
                let bi = NSMenuItem(title: "\(f) frames",
                                    action: #selector(selectBufferSize(_:)), keyEquivalent: "")
                bi.target = self
                bi.representedObject = f
                bi.state = (f == currentBuf) ? .on : .off
                bufMenu.addItem(bi)
            }
            bufItem.submenu = bufMenu
            menu.addItem(bufItem)
        }

        // ---- Idle timeout submenu ----
        if !settings.isHidden(.idleTimer) {
            menu.addItem(.separator())
            let idleItem = NSMenuItem(title: idleTimeoutSeconds == 0
                                      ? "Idle Timeout: Off"
                                      : "Idle Timeout: \(idleLabel(idleTimeoutSeconds))",
                                      action: nil, keyEquivalent: "")
            let idleMenu = NSMenu()
            let idleOptions: [(String, Int)] = [
                ("Off", 0), ("15 seconds", 15), ("30 seconds", 30),
                ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
                ("10 minutes", 600), ("30 minutes", 1800)
            ]
            for (label, secs) in idleOptions {
                let mi = NSMenuItem(title: label, action: #selector(selectIdleTimeout(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = secs
                mi.state = (secs == idleTimeoutSeconds) ? .on : .off
                idleMenu.addItem(mi)
            }
            idleItem.submenu = idleMenu
            menu.addItem(idleItem)
        }

        menu.addItem(.separator())

        // ---- Refresh ----
        if !settings.isHidden(.refresh) {
            let refresh = NSMenuItem(title: "Refresh Audio Routing",
                                     action: #selector(refreshPipeline), keyEquivalent: "r")
            refresh.target = self
            refresh.isEnabled = engine.isRunning
            menu.addItem(refresh)
        }

        // ---- Settings (never hideable) ----
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // ---- Help ----
        if !settings.isHidden(.help) {
            let help = NSMenuItem(title: "How This App Works…",
                                  action: #selector(showHelpFromMenu), keyEquivalent: "?")
            help.target = self
            menu.addItem(help)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Central handler: if the system default output differs from what the
    /// engine is currently bound to, rebuild routing to follow it.
    private func outputMayHaveChanged() {
        let now = AudioDevices.defaultOutput()
        if now != lastKnownOutputID {
            lastKnownOutputID = now
            if engine.isRunning { engine.refresh() }
        }
        rebuildMenu()
    }

    // MARK: - Status button click routing

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Right-click toggles listening directly.
            togglePassthrough()
        } else {
            // Left-click opens the menu just below the icon.
            rebuildMenu()
            let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }
    }

    // MARK: - Actions

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        selectedInputID = id
        saveSelectedInput()
        // Reset volume to unity when the input changes.
        inputVolume = 1.0
        applyVolumeToEngine()
        UserDefaults.standard.set(Float(1.0), forKey: "inputVolume")
        volumeMenuView?.setGain(1.0)
        // Changing the input only restarts if already listening; it doesn't
        // start on its own (use Start Listening or the setup panel for that).
        if engine.isRunning {
            restart()
        }
        rebuildMenu()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        if engine.setOutputDevice(id) {
            lastKnownOutputID = id
        } else {
            warn("Couldn’t switch output device. It may be in use or unavailable.")
        }
        rebuildMenu()
    }

    // MARK: - Engine management

    private func wireEngineCallbacks() {
        engine.onInputLostWarning = { [weak self] msg in
            DispatchQueue.main.async { self?.warn(msg); self?.rebuildMenu() }
        }
    }

    /// Swap the active engine, carrying over settings and restarting if needed.
    private func switchEngine(to kind: EngineKind) {
        guard kind != engineKind else { return }

        // Preserve settings and running state.
        let wasRunning = engine.isRunning
        let rate = engine.desiredSampleRate
        let frames = engine.desiredBufferFrames
        let input = selectedInputID
        engine.stop()

        switch kind {
        case .avAudioEngine: engine = PassthroughEngine()
        case .aggregateHAL:  engine = AggregateHALEngine()
        case .dualDeviceHAL: engine = DualDeviceHALEngine()
        }
        engineKind = kind
        engine.desiredSampleRate = rate
        engine.desiredBufferFrames = frames
        engine.volume = actualGain(forDisplay: inputVolume)
        AppSettings.shared.engineKind = kind
        wireEngineCallbacks()

        if wasRunning, let id = input {
            do { try engine.start(inputDeviceID: id); startIdlePollIfNeeded() }
            catch { warn("Couldn’t start \(kind.title): \(error.localizedDescription)") }
        }
        updateStatusIcon(active: engine.isRunning)
        rebuildMenu()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = EngineKind(rawValue: raw) else { return }
        switchEngine(to: kind)
    }

    @objc private func selectIdleTimeout(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        idleTimeoutSeconds = secs
        UserDefaults.standard.set(secs, forKey: "idleTimeoutSeconds")
        // Switching timer options restarts the countdown from scratch.
        silentSince = nil
        if engine.isRunning {
            startIdlePollIfNeeded()
            // Clear any visible countdown back to the plug icon; the next poll
            // re-shows a countdown only if the input is currently silent.
            updateStatusIcon(active: true)
        }
        rebuildMenu()
    }

    private func idleLabel(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    // MARK: - Idle detection

    private func startIdlePollIfNeeded() {
        stopIdlePoll()
        guard idleTimeoutSeconds > 0 else { return }
        silentSince = nil
        // Poll ~4x/sec; cheap and responsive enough for a timeout.
        idlePollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    private func stopIdlePoll() {
        idlePollTimer?.invalidate()
        idlePollTimer = nil
        silentSince = nil
    }

    private func checkIdle() {
        guard engine.isRunning, idleTimeoutSeconds > 0 else { return }
        let level = engine.currentPeakLevel
        if level >= silenceThreshold {
            // Audio present: reset the clock and, if we were showing a countdown,
            // restore the app icon.
            if silentSince != nil {
                silentSince = nil
                updateStatusIcon(active: true)
            }
            return
        }
        // Silence.
        if silentSince == nil {
            silentSince = Date()
        }
        if let since = silentSince {
            let elapsed = Date().timeIntervalSince(since)
            // Grace period: don't begin the countdown until silence has persisted
            // for a few seconds, so brief pauses don't kick off the timer.
            guard elapsed >= silenceGracePeriod else { return }
            let remaining = Double(idleTimeoutSeconds) - (elapsed - silenceGracePeriod)
            if remaining <= 0 {
                // Timed out — stop listening.
                engine.stop()
                stopIdlePoll()
                updateStatusIcon(active: false)
                rebuildMenu()
                return
            }
            updateCountdownIcon(remaining: Int(ceil(remaining)))
        }
    }

    /// Big-font countdown shown in the menu bar while silence is being timed.
    /// Format depends on the user's chosen countdown style; color and layout
    /// (replace icon vs. beside icon at 50%) follow their settings.
    private func updateCountdownIcon(remaining seconds: Int) {
        let settings = AppSettings.shared
        let text: String
        switch settings.countdownStyle {
        case .rounded:
            if seconds >= 60 {
                text = "\(Int(ceil(Double(seconds) / 60.0)))m"
            } else {
                text = "\(seconds)s"
            }
        case .seconds:
            if seconds >= 60 {
                text = String(format: "%d:%02d", seconds / 60, seconds % 60)
            } else {
                text = "\(seconds)"
            }
        }

        let color = settings.timerColor.nsColor
        guard let button = statusItem.button else { return }

        // Base font size scaled by the user's timer text size (100% = 15pt).
        let scale = CGFloat(settings.timerTextScale) / 100.0
        let fontSize = 15.0 * scale

        // Render into an image so the status item centers it reliably at any size
        // (attributed-title baseline centering drifts with font size).
        let plug = (settings.timerLayout == .compact) ? loadTemplateImage(named: "plug_on") : nil
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.image = timerImage(text: text, size: fontSize, color: color, leadingIcon: plug)
    }

    /// Draws the countdown text (optionally preceded by the plug icon) into a
    /// vertically-centered image sized to the menu bar height.
    private func timerImage(text: String, size: CGFloat, color: NSColor, leadingIcon: NSImage?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let barHeight: CGFloat = 22        // standard menu-bar height
        // Plug scales with the font size (base 18pt at 100% / 15pt font).
        let iconSide: CGFloat = leadingIcon != nil ? min(barHeight, max(10, size * 1.2)) : 0
        let gap: CGFloat = leadingIcon != nil ? 3 : 0
        let width = ceil(iconSide + gap + textSize.width) + 2
        let image = NSImage(size: NSSize(width: width, height: barHeight))

        image.lockFocus()
        var x: CGFloat = 1
        if let icon = leadingIcon {
            let iconRect = NSRect(x: x, y: (barHeight - iconSide) / 2, width: iconSide, height: iconSide)
            // Tint the template plug to the accent color instead of raw black.
            let tinted = tintedImage(icon, color: color)
            tinted.draw(in: iconRect)
            x += iconSide + gap
        }
        // Center text vertically using its actual bounding box.
        let ty = (barHeight - textSize.height) / 2
        (text as NSString).draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
        image.unlockFocus()

        // Non-template so the chosen color is preserved (template would flatten it).
        image.isTemplate = false
        return image
    }

    /// Returns a copy of a template image filled with the given color.
    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    // MARK: - Setup panel (boot)

    private func showSetupPanel() {
        let panel = SetupPanelController(
            inputID: selectedInputID,
            outputID: AudioDevices.defaultOutput(),
            idle: idleTimeoutSeconds,
            mode: activeMode ?? .game,
            volume: inputVolume)

        panel.onStart = { [weak self] inputID, outputID, idle, mode, volume in
            guard let self = self else { return }
            self.selectedInputID = inputID
            self.saveSelectedInput()
            AudioDevices.setDefaultOutput(outputID)
            self.lastKnownOutputID = outputID
            self.idleTimeoutSeconds = idle
            UserDefaults.standard.set(idle, forKey: "idleTimeoutSeconds")
            self.inputVolume = volume
            self.applyVolumeToEngine()
            UserDefaults.standard.set(volume, forKey: "inputVolume")
            self.applyMode(mode)

            self.restart()
            self.applyVolumeToEngine() // reassert after (re)start
            if self.engine.isRunning { self.startIdlePollIfNeeded() }
            self.updateStatusIcon(active: self.engine.isRunning)
            self.rebuildMenu()
            self.setupPanel = nil
        }

        // Live volume changes while the panel is open (if already listening).
        panel.onVolumeChange = { [weak self] v in
            guard let self = self else { return }
            self.inputVolume = v
            self.applyVolumeToEngine()
            UserDefaults.standard.set(v, forKey: "inputVolume")
        }

        // Slider type changed in the panel — reflect it in the menu-bar slider.
        panel.onSliderTypeChange = { [weak self] _ in
            self?.rebuildMenu()
        }

        panel.onQuit = { NSApp.terminate(nil) }

        setupPanel = panel
        panel.present()
    }

    // MARK: - Settings panel

    private func showSettingsPanel() {
        let panel = SettingsPanelController()

        panel.onEngineChange = { [weak self] kind in
            self?.switchEngine(to: kind)
        }
        panel.onChanged = { [weak self] in
            self?.rebuildMenu()
        }
        panel.onResetAll = { [weak self] in
            guard let self = self else { return }
            // Re-apply defaults to live state.
            self.idleTimeoutSeconds = 300
            self.inputVolume = 1.0
            self.applyVolumeToEngine()
            self.selectedInputID = nil
            if self.engineKind != AppSettings.shared.engineKind {
                self.switchEngine(to: AppSettings.shared.engineKind)
            }
            self.applyMode(.game)
            self.rebuildMenu()
        }
        // Master limit / boost changed in Settings — reapply gain and rebuild
        // the menu so the volume slider reflects the new ceiling.
        panel.onVolumeConfigChange = { [weak self] in
            guard let self = self else { return }
            self.applyVolumeToEngine()
            // Accent color / font size can affect the plug icon — refresh it,
            // unless a countdown is currently drawn (the poll will redraw that).
            if self.silentSince == nil {
                self.updateStatusIcon(active: self.engine.isRunning)
            }
            self.rebuildMenu()
        }

        settingsPanel = panel
        panel.present()
    }

    // MARK: - Help window

    @objc private func showHelpFromMenu() { showHelpWindow() }

    @objc private func openSettingsFromMenu() { showSettingsPanel() }

    private func showHelpWindow() {
        if let win = helpWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = HelpWindow.make()
        win.isReleasedWhenClosed = false
        helpWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Modes

    private func modeRaw(_ mode: Preset) -> String {
        switch mode {
        case .game:   return "game"
        case .stereo: return "stereo"
        case .ultra:  return "ultra"
        case .custom: return "custom"
        }
    }

    private func modeFromRaw(_ raw: String) -> Preset? {
        switch raw {
        case "game":   return .game
        case "stereo": return .stereo
        case "ultra":  return .ultra
        case "custom": return .custom
        default:       return nil
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = modeFromRaw(raw) else { return }
        applyMode(mode)
    }

    private func applyMode(_ mode: Preset) {
        activeMode = mode
        // Custom changes nothing — just record it as the active mode.
        guard mode.changesSettings else { rebuildMenu(); return }
        // A mode may prescribe an engine; switch to it if so.
        if let kind = mode.engine, kind != engineKind {
            switchEngine(to: kind)
        }
        engine.applyPreset(mode)
        rebuildMenu()
    }

    @objc private func selectBufferSize(_ sender: NSMenuItem) {
        guard let frames = sender.representedObject as? UInt32 else { return }
        engine.setBufferFrames(frames)
        rebuildMenu()
    }

    @objc private func refreshPipeline() {
        engine.refresh()
        rebuildMenu()
    }

    @objc private func togglePassthrough() {
        if engine.isRunning {
            engine.stop()
            stopIdlePoll()
        } else {
            // Require both an input and an output; otherwise prompt via setup.
            guard selectedInputID != nil, AudioDevices.defaultOutput() != 0 else {
                let alert = NSAlert()
                alert.messageText = "Select an input and output"
                alert.informativeText = "Choose an input and output device before starting. Opening setup so you can pick them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Setup")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { showSetupPanel() }
                return
            }
            restart()
            if engine.isRunning { startIdlePollIfNeeded() }
        }
        updateStatusIcon(active: engine.isRunning)
        rebuildMenu()
    }

    private func restart() {
        guard let id = selectedInputID else { return }
        do {
            try engine.start(inputDeviceID: id)
            lastKnownOutputID = AudioDevices.defaultOutput()
        } catch {
            warn("Couldn’t start passthrough: \(error.localizedDescription)")
        }
        updateStatusIcon(active: engine.isRunning)
    }

    // MARK: - UI helpers

    private func updateStatusIcon(active: Bool) {
        // Clear any countdown text before restoring the icon.
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly

        let settings = AppSettings.shared
        // Plug size scales with the Font Size setting (base 18pt at 100%),
        // capped to the menu-bar height.
        let side = min(22, max(12, 18 * CGFloat(settings.timerTextScale) / 100.0))

        // Prefer the bundled 3.5mm plug icon (solid = on, outline = off).
        let iconName = active ? "plug_on" : "plug_off"
        if let img = loadTemplateImage(named: iconName, side: side) {
            // Tint to the chosen accent color; keep template only for the default
            // "accent = system" case so it still adapts to light/dark menu bars.
            if settings.timerColor == .accent {
                img.isTemplate = true
                statusItem.button?.image = img
            } else {
                statusItem.button?.image = tintedImage(img, color: settings.timerColor.nsColor)
            }
            return
        }
        // Fallback to an SF Symbol if the asset is missing.
        let symbol = active ? "waveform.circle.fill" : "waveform.circle"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "LL Input") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = active ? "▶︎" : "◼︎"
        }
    }

    /// Loads a menu-bar template image from the app bundle's Resources at a size.
    private func loadTemplateImage(named base: String, side: CGFloat = 18) -> NSImage? {
        let candidates = ["\(base)@2x", base]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: side, height: side)
                return img
            }
        }
        return nil
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LL Input"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }
}
