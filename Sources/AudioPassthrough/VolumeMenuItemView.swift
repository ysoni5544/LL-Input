import Cocoa

/// A slider embedded in a menu item for adjusting input volume. Honors the
/// current SliderType (bipolar ±dB or linear 0–200%) and reports linear gain.
final class VolumeMenuItemView: NSView {

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "Volume")
    private let resetButton = NSButton()
    private let sliderType: SliderType
    var onChange: ((Float) -> Void)?

    init(gain: Float, sliderType: SliderType) {
        self.sliderType = sliderType
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        build(initialGain: gain)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(initialGain: Float) {
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        switch sliderType {
        case .linear:
            slider.minValue = 0; slider.maxValue = 2
        case .bipolar:
            slider.minValue = -1; slider.maxValue = 1
            slider.numberOfTickMarks = 3
        }
        slider.doubleValue = position(forGain: initialGain)
        valueLabel.stringValue = text(forGain: initialGain)

        resetButton.title = "Reset"
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = NSFont.systemFont(ofSize: 10)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(slider)
        addSubview(valueLabel)
        addSubview(resetButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            resetButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 56),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    @objc private func resetTapped() {
        setGain(1.0)
        onChange?(1.0)
    }

    @objc private func changed() {
        let g = gain(forPosition: slider.doubleValue)
        valueLabel.stringValue = text(forGain: g)
        onChange?(g)
    }

    /// Update the control from outside (e.g. after an input-change reset).
    func setGain(_ g: Float) {
        slider.doubleValue = position(forGain: g)
        valueLabel.stringValue = text(forGain: g)
    }

    // MARK: - Mapping

    private func position(forGain gain: Float) -> Double {
        switch sliderType {
        case .linear:
            return Double(min(max(gain, 0), 2))
        case .bipolar:
            if gain <= 0 { return -1 }
            let db = 20 * log10(gain)
            return Double(min(max(db / 12, -1), 1))
        }
    }

    private func gain(forPosition pos: Double) -> Float {
        switch sliderType {
        case .linear:
            return Float(pos)
        case .bipolar:
            return pow(10, Float(pos) * 12 / 20)
        }
    }

    private func text(forGain gain: Float) -> String {
        switch sliderType {
        case .linear:
            return "\(Int(round(gain * 100)))%"
        case .bipolar:
            if gain <= 0 { return "-∞" }
            return String(format: "%+.0f dB", 20 * log10(gain))
        }
    }
}
