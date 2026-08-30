import Cocoa
import CoreAudio

/// Shown once on app boot. Lets the user pick input, output, idle timer, and mode,
/// then start listening (closes the panel) or quit the app.
final class SetupPanelController: NSWindowController {

    // Current selections, seeded from the app's restored state.
    var selectedInputID: AudioDeviceID?
    var selectedOutputID: AudioDeviceID
    var idleTimeoutSeconds: Int
    var mode: Preset
    var volume: Float // linear 0…1 (1.0 = unity)

    // Callbacks to the app.
    var onStart: ((_ inputID: AudioDeviceID, _ outputID: AudioDeviceID,
                   _ idle: Int, _ mode: Preset, _ volume: Float) -> Void)?
    var onQuit: (() -> Void)?
    var onVolumeChange: ((Float) -> Void)?
    var onSliderTypeChange: ((SliderType) -> Void)?

    private var inputPopup: NSPopUpButton!
    private var outputPopup: NSPopUpButton!
    private var timerPopup: NSPopUpButton!
    private var modePopup: NSPopUpButton!
    private var volumeSlider: NSSlider!
    private var volumeLabel: NSTextField!
    private var sliderTypePopup: NSPopUpButton!
    private var sliderType = AppSettings.shared.sliderType
    private let sliderTypeOptions: [SliderType] = SliderType.allCases

    private var inputDevices: [AudioDevice] = []
    private var outputDevices: [AudioDevice] = []

    private let timerOptions: [(String, Int)] = [
        ("Off", 0), ("15 seconds", 15), ("30 seconds", 30),
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
        ("10 minutes", 600), ("30 minutes", 1800)
    ]
    private let modeOptions: [Preset] = [.game, .stereo, .ultra, .custom]

    init(inputID: AudioDeviceID?, outputID: AudioDeviceID, idle: Int, mode: Preset, volume: Float) {
        self.selectedInputID = inputID
        self.selectedOutputID = outputID
        self.idleTimeoutSeconds = idle
        self.mode = mode
        self.volume = volume

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "LL Input — Setup"
        win.center()
        // Float above all windows, including other apps' windows.
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        inputDevices = AudioDevices.inputs()
        outputDevices = AudioDevices.outputs()

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 12

        inputPopup = makePopup(inputDevices.map { $0.name })
        selectPopup(inputPopup, deviceList: inputDevices, id: selectedInputID)
        inputPopup.target = self
        inputPopup.action = #selector(inputChanged)

        outputPopup = makePopup(outputDevices.map { $0.name })
        selectPopup(outputPopup, deviceList: outputDevices, id: selectedOutputID)

        timerPopup = makePopup(timerOptions.map { $0.0 })
        if let idx = timerOptions.firstIndex(where: { $0.1 == idleTimeoutSeconds }) {
            timerPopup.selectItem(at: idx)
        }

        modePopup = makePopup(modeOptions.map { $0.title })
        if let idx = modeOptions.firstIndex(of: mode) {
            modePopup.selectItem(at: idx)
        }

        sliderTypePopup = makePopup(sliderTypeOptions.map { $0.title })
        if let idx = sliderTypeOptions.firstIndex(of: sliderType) {
            sliderTypePopup.selectItem(at: idx)
        }
        sliderTypePopup.target = self
        sliderTypePopup.action = #selector(sliderTypeChanged)

        buildVolumeControls()

        grid.addRow(with: [label("Input:"), inputPopup, infoButton(.input)])
        grid.addRow(with: [label("Volume Type:"), sliderTypePopup, infoButton(.volumeType)])
        grid.addRow(with: [label("Volume:"), volumeStack(), infoButton(.volume)])
        grid.addRow(with: [label("Output:"), outputPopup, infoButton(.output)])
        grid.addRow(with: [label("Idle Timer:"), timerPopup, infoButton(.timer)])
        grid.addRow(with: [label("Mode:"), modePopup, infoButton(.mode)])

        // Buttons.
        let startButton = NSButton(title: "Start Listening", target: self, action: #selector(startTapped))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r" // Enter triggers Start
        startButton.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Close Application", target: self, action: #selector(quitTapped))
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [quitButton, startButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    // MARK: - Volume slider

    private func buildVolumeControls() {
        volumeSlider = NSSlider(target: self, action: #selector(volumeChanged))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.isContinuous = true
        volumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        applySliderRange()
        volumeSlider.doubleValue = sliderPosition(forGain: volume)

        volumeLabel = NSTextField(labelWithString: volumeText(forGain: volume))
        volumeLabel.alignment = .left
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        volumeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    private func applySliderRange() {
        switch sliderType {
        case .linear:
            volumeSlider.minValue = 0
            volumeSlider.maxValue = 2
            volumeSlider.numberOfTickMarks = 0
        case .bipolar:
            volumeSlider.minValue = -1
            volumeSlider.maxValue = 1
            volumeSlider.numberOfTickMarks = 3 // visual center detent hint
        }
    }

    @objc private func sliderTypeChanged() {
        let idx = max(0, sliderTypePopup.indexOfSelectedItem)
        sliderType = sliderTypeOptions[idx]
        AppSettings.shared.sliderType = sliderType // persist the choice
        onSliderTypeChange?(sliderType)
        // Reconfigure the volume slider for the new type, preserving current gain.
        applySliderRange()
        volumeSlider.doubleValue = sliderPosition(forGain: volume)
        volumeLabel.stringValue = volumeText(forGain: volume)
    }

    private func volumeStack() -> NSStackView {
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetVolumeTapped))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.toolTip = "Reset volume to default (unity)"
        let s = NSStackView(views: [volumeSlider, volumeLabel, reset])
        s.orientation = .horizontal
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    @objc private func resetVolumeTapped() {
        volume = 1.0
        volumeSlider.doubleValue = sliderPosition(forGain: 1.0)
        volumeLabel.stringValue = volumeText(forGain: 1.0)
        onVolumeChange?(1.0)
    }

    /// Map a linear gain (0…~4) to the slider position for the active type.
    private func sliderPosition(forGain gain: Float) -> Double {
        switch sliderType {
        case .linear:
            return Double(min(max(gain, 0), 2))
        case .bipolar:
            // gain = 10^(dB/20), dB = position*12  → position = 20*log10(gain)/12
            if gain <= 0 { return -1 }
            let db = 20 * log10(gain)
            return Double(min(max(db / 12, -1), 1))
        }
    }

    /// Map the slider position to a linear gain for the active type.
    private func gain(forPosition pos: Double) -> Float {
        switch sliderType {
        case .linear:
            return Float(pos) // 0…1
        case .bipolar:
            let db = Float(pos) * 12 // ±12 dB
            return pow(10, db / 20)
        }
    }

    private func volumeText(forGain gain: Float) -> String {
        switch sliderType {
        case .linear:
            return "\(Int(round(gain * 100)))%"
        case .bipolar:
            if gain <= 0 { return "-∞" }
            let db = 20 * log10(gain)
            return String(format: "%+.0f dB", db)
        }
    }

    @objc private func volumeChanged() {
        volume = gain(forPosition: volumeSlider.doubleValue)
        volumeLabel.stringValue = volumeText(forGain: volume)
        onVolumeChange?(volume)
    }

    @objc private func inputChanged() {
        // Reset volume to unity whenever the input device changes.
        volume = 1.0
        volumeSlider.doubleValue = sliderPosition(forGain: 1.0)
        volumeLabel.stringValue = volumeText(forGain: 1.0)
        onVolumeChange?(1.0)
    }

    // MARK: - Info tooltips

    private enum InfoField: Int {
        case input, volumeType, volume, output, timer, mode

        var text: String {
            switch self {
            case .input:
                return "The device to listen to — normally your 3.5mm line-in. This is the audio that gets passed through to your speakers. It stays pinned while listening; if it disappears, the app warns you."
            case .volumeType:
                return "How the volume slider behaves. Type A is centered at 0 dB — left cuts, right boosts (±12 dB). Type B is a straight 0–200% level. This choice also applies to the volume slider in the menu bar."
            case .volume:
                return "Adjusts the level of the passed-through input. Type A is centered at 0 dB — move left to cut, right to boost. Type B runs 0–200%. Volume resets to default whenever you change the input device."
            case .output:
                return "Where the sound plays: built-in speakers, headphones, or any connected output. You can change it later from the menu, and the passthrough follows the change."
            case .timer:
                return "Automatically stops listening after this much silence on the input, so the app isn't holding your devices when nothing is playing. While counting down, the menu bar shows the remaining time; any sound resets it. Choose Off to disable."
            case .mode:
                return "A one-click latency preset (all at 48 kHz). Game Mode uses a 256-frame buffer — a balanced, safe low latency. Stereo Mode picks the best-supported buffer for your device. Ultra Latency Mode uses a 64-frame buffer for the absolute lowest latency, if your hardware keeps up without dropouts."
            }
        }
    }

    private func infoButton(_ field: InfoField) -> NSButton {
        let b: NSButton
        if let img = NSImage(systemSymbolName: "questionmark.circle",
                             accessibilityDescription: "Info") {
            b = NSButton(image: img, target: self, action: #selector(infoTapped(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.imageScaling = .scaleProportionallyDown
        } else {
            b = NSButton(title: "?", target: self, action: #selector(infoTapped(_:)))
            b.bezelStyle = .helpButton
        }
        b.tag = field.rawValue
        b.toolTip = field.text // also works as a hover tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    @objc private func infoTapped(_ sender: NSButton) {
        guard let field = InfoField(rawValue: sender.tag) else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))

        let text = NSTextField(wrappingLabelWithString: field.text)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = NSFont.systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = 276
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        vc.view = container
        popover.contentViewController = vc

        // Measure wrapped height at the fixed content width.
        let measured = (field.text as NSString).boundingRect(
            with: NSSize(width: 276, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        popover.contentSize = NSSize(width: 300, height: ceil(measured.height) + 24)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    private func makePopup(_ titles: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.translatesAutoresizingMaskIntoConstraints = false
        if titles.isEmpty {
            p.addItem(withTitle: "None available")
            p.isEnabled = false
        } else {
            p.addItems(withTitles: titles)
        }
        p.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return p
    }

    private func selectPopup(_ popup: NSPopUpButton, deviceList: [AudioDevice], id: AudioDeviceID?) {
        if let id = id, let idx = deviceList.firstIndex(where: { $0.id == id }) {
            popup.selectItem(at: idx)
        }
    }

    // MARK: - Actions

    @objc private func startTapped() {
        guard !inputDevices.isEmpty, !outputDevices.isEmpty else {
            NSSound.beep()
            return
        }
        let inputID = inputDevices[max(0, inputPopup.indexOfSelectedItem)].id
        let outputID = outputDevices[max(0, outputPopup.indexOfSelectedItem)].id
        let idle = timerOptions[max(0, timerPopup.indexOfSelectedItem)].1
        let chosenMode = modeOptions[max(0, modePopup.indexOfSelectedItem)]

        onStart?(inputID, outputID, idle, chosenMode, volume)
        close()
    }

    @objc private func quitTapped() {
        onQuit?()
    }
}
