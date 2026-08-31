import Cocoa

/// App settings window: slider type, engine, menu-visibility toggles, and resets.
final class SettingsPanelController: NSWindowController {

    // Callbacks to the app.
    var onEngineChange: ((EngineKind) -> Void)?
    var onChanged: (() -> Void)?           // rebuild menu after a visibility/reset change
    var onResetAll: (() -> Void)?          // app re-applies defaults broadly
    var onVolumeConfigChange: (() -> Void)? // boost/master-limit changed

    private let settings = AppSettings.shared
    private var sliderPopup: NSPopUpButton!
    private var enginePopup: NSPopUpButton!
    private var launchAtLoginCheck: NSButton!
    private var boostCheck: NSButton!
    private var masterSlider: NSSlider!
    private var masterLabel: NSTextField!
    private var hideChecks: [(MenuOption, NSButton)] = []

    private let sliderTypes: [SliderType] = SliderType.allCases
    private let engines: [EngineKind] = EngineKind.allCases

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "LL Input — Settings"
        win.center()
        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        // --- Volume slider type ---
        // --- General ---
        stack.addArrangedSubview(sectionTitle("General"))
        launchAtLoginCheck = NSButton(checkboxWithTitle: "Launch at login",
                                      target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheck.state = LoginItem.isEnabled ? .on : .off
        stack.addArrangedSubview(launchAtLoginCheck)

        // --- Volume slider type ---
        stack.addArrangedSubview(sectionTitle("Volume Slider Type"))
        sliderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sliderPopup.addItems(withTitles: sliderTypes.map { $0.title })
        if let idx = sliderTypes.firstIndex(of: settings.sliderType) {
            sliderPopup.selectItem(at: idx)
        }
        sliderPopup.target = self
        sliderPopup.action = #selector(sliderTypeChanged)
        stack.addArrangedSubview(sliderPopup)

        // --- Volume limits ---
        stack.addArrangedSubview(sectionTitle("Volume"))
        boostCheck = NSButton(checkboxWithTitle: "Allow boost above 100% (up to 200%)",
                              target: self, action: #selector(boostToggled(_:)))
        boostCheck.state = settings.boostEnabled ? .on : .off
        stack.addArrangedSubview(boostCheck)

        let masterCaption = NSTextField(labelWithString: "Master Input Volume Limit")
        masterCaption.font = NSFont.systemFont(ofSize: 12)
        masterCaption.textColor = .secondaryLabelColor
        stack.addArrangedSubview(masterCaption)

        masterSlider = NSSlider(target: self, action: #selector(masterChanged))
        masterSlider.isContinuous = true
        masterSlider.minValue = 0
        masterSlider.maxValue = Double(settings.maxGain)
        masterSlider.doubleValue = Double(settings.masterLimit)
        masterSlider.translatesAutoresizingMaskIntoConstraints = false

        masterLabel = NSTextField(labelWithString: masterText())
        masterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        masterLabel.textColor = .secondaryLabelColor
        masterLabel.translatesAutoresizingMaskIntoConstraints = false
        masterLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let masterRow = NSStackView(views: [masterSlider, masterLabel])
        masterRow.orientation = .horizontal
        masterRow.spacing = 8
        masterRow.translatesAutoresizingMaskIntoConstraints = false
        masterSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        stack.addArrangedSubview(masterRow)

        // --- Engine ---
        stack.addArrangedSubview(sectionTitle("Audio Engine"))
        enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.addItems(withTitles: engines.map { $0.title })
        if let idx = engines.firstIndex(of: settings.engineKind) {
            enginePopup.selectItem(at: idx)
        }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        stack.addArrangedSubview(enginePopup)

        // --- Menu visibility ---
        stack.addArrangedSubview(sectionTitle("Show Menu Items"))
        for option in MenuOption.allCases where option.canHide {
            let cb = NSButton(checkboxWithTitle: option.title, target: self,
                              action: #selector(hideToggled(_:)))
            cb.state = settings.isHidden(option) ? .off : .on // checked = shown
            cb.tag = MenuOption.allCases.firstIndex(of: option) ?? 0
            hideChecks.append((option, cb))
            stack.addArrangedSubview(cb)
        }

        // --- Reset buttons ---
        let resetHides = NSButton(title: "Reset Menu Visibility",
                                  target: self, action: #selector(resetHidesTapped))
        resetHides.bezelStyle = .rounded

        let resetAll = NSButton(title: "Reset All Settings",
                                target: self, action: #selector(resetAllTapped))
        resetAll.bezelStyle = .rounded

        let resetRow = NSStackView(views: [resetHides, resetAll])
        resetRow.orientation = .horizontal
        resetRow.spacing = 12
        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(resetRow)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 13)
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: - Actions

    private func masterText() -> String {
        "\(Int(round(settings.masterLimit * 100)))%"
    }

    @objc private func boostToggled(_ sender: NSButton) {
        settings.boostEnabled = (sender.state == .on)
        // Rescale the master slider's range to the new ceiling and clamp value.
        masterSlider.maxValue = Double(settings.maxGain)
        // masterLimit getter already clamps to maxGain; reflect it in the UI.
        masterSlider.doubleValue = Double(settings.masterLimit)
        masterLabel.stringValue = masterText()
        onVolumeConfigChange?()
    }

    @objc private func masterChanged() {
        settings.masterLimit = Float(masterSlider.doubleValue)
        masterLabel.stringValue = masterText()
        onVolumeConfigChange?()
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let want = (sender.state == .on)
        if !LoginItem.setEnabled(want) {
            // Revert the checkbox if the system rejected the change.
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn’t update Launch at Login"
            alert.informativeText = "macOS blocked the change. You can manage login items in System Settings › General › Login Items."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func sliderTypeChanged() {
        let idx = max(0, sliderPopup.indexOfSelectedItem)
        settings.sliderType = sliderTypes[idx]
    }

    @objc private func engineChanged() {
        let idx = max(0, enginePopup.indexOfSelectedItem)
        let kind = engines[idx]
        settings.engineKind = kind
        onEngineChange?(kind)
    }

    @objc private func hideToggled(_ sender: NSButton) {
        guard let pair = hideChecks.first(where: { $0.1 == sender }) else { return }
        // Checked = shown, so hidden = (state == .off).
        settings.setHidden(pair.0, sender.state == .off)
        onChanged?()
    }

    @objc private func resetHidesTapped() {
        settings.resetHiddenToDefault()
        // Re-check all boxes.
        for (_, cb) in hideChecks { cb.state = .on }
        onChanged?()
    }

    @objc private func resetAllTapped() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "This restores slider type, engine, menu visibility, saved input, volume, and idle timeout to defaults."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        settings.resetAllToDefault()
        // Reflect defaults in the UI.
        if let idx = sliderTypes.firstIndex(of: settings.sliderType) { sliderPopup.selectItem(at: idx) }
        if let idx = engines.firstIndex(of: settings.engineKind) { enginePopup.selectItem(at: idx) }
        boostCheck.state = settings.boostEnabled ? .on : .off
        masterSlider.maxValue = Double(settings.maxGain)
        masterSlider.doubleValue = Double(settings.masterLimit)
        masterLabel.stringValue = masterText()
        for (_, cb) in hideChecks { cb.state = .on }
        onResetAll?()
        onChanged?()
    }
}
