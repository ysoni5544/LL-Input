import Foundation

/// Which menu rows can be hidden via Settings.
enum MenuOption: String, CaseIterable {
    case startStop, input, volume, output, modes, buffer, idleTimer, refresh, help, settings

    var title: String {
        switch self {
        case .startStop: return "Start / Stop Listening"
        case .input:     return "Input"
        case .volume:    return "Input Volume"
        case .output:    return "Output"
        case .modes:     return "Modes"
        case .buffer:    return "Buffer Size"
        case .idleTimer: return "Idle Timeout"
        case .refresh:   return "Refresh Audio Routing"
        case .help:      return "How This App Works…"
        case .settings:  return "Settings…"
        }
    }

    /// Rows that must never be hideable (you'd lose access to core control).
    var canHide: Bool {
        switch self {
        case .startStop, .settings: return false
        default: return true
        }
    }
}

/// Volume slider style.
enum SliderType: String, CaseIterable {
    case bipolar   // Type A: center = 0, left cuts, right boosts
    case linear    // Type B: 0…200%

    var title: String {
        switch self {
        case .bipolar: return "Type A — center 0, ± gain"
        case .linear:  return "Type B — 0 to 200%"
        }
    }
}

/// Central, persisted app settings.
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum Key {
        static let sliderType = "sliderType"
        static let hidden = "hiddenMenuOptions"
        static let engine = "engineKind"
        static let boostEnabled = "boostEnabled"
        static let masterLimit = "masterVolumeLimit"
    }

    var sliderType: SliderType {
        get { SliderType(rawValue: d.string(forKey: Key.sliderType) ?? "") ?? .linear }
        set { d.set(newValue.rawValue, forKey: Key.sliderType) }
    }

    /// When true, volume can be boosted up to 200% (2.0x); otherwise capped at 100%.
    var boostEnabled: Bool {
        get { d.bool(forKey: Key.boostEnabled) } // defaults to false (100% cap)
        set { d.set(newValue, forKey: Key.boostEnabled) }
    }

    /// The maximum linear gain allowed by the boost setting (1.0 or 2.0).
    var maxGain: Float { boostEnabled ? 2.0 : 1.0 }

    /// Master volume limit as a linear gain (the ceiling the menu-bar slider's
    /// 100% maps to). Ranges 0…maxGain. Defaults to maxGain (no extra limiting).
    var masterLimit: Float {
        get {
            if d.object(forKey: Key.masterLimit) == nil { return maxGain }
            return min(d.float(forKey: Key.masterLimit), maxGain)
        }
        set { d.set(min(max(0, newValue), maxGain), forKey: Key.masterLimit) }
    }

    var hiddenOptions: Set<MenuOption> {
        get {
            let raw = d.array(forKey: Key.hidden) as? [String] ?? []
            return Set(raw.compactMap { MenuOption(rawValue: $0) })
        }
        set { d.set(newValue.map { $0.rawValue }, forKey: Key.hidden) }
    }

    func isHidden(_ option: MenuOption) -> Bool { hiddenOptions.contains(option) }

    func setHidden(_ option: MenuOption, _ hidden: Bool) {
        guard option.canHide else { return }
        var set = hiddenOptions
        if hidden { set.insert(option) } else { set.remove(option) }
        hiddenOptions = set
    }

    var engineKind: EngineKind {
        get { EngineKind(rawValue: d.string(forKey: Key.engine) ?? "") ?? .dualDeviceHAL }
        set { d.set(newValue.rawValue, forKey: Key.engine) }
    }

    // MARK: - Resets

    /// Reset only the hidden-menu configuration (show everything).
    func resetHiddenToDefault() {
        d.removeObject(forKey: Key.hidden)
    }

    /// Reset every app setting to defaults, including remembered device/timeout.
    func resetAllToDefault() {
        for key in [Key.sliderType, Key.hidden, Key.engine, Key.boostEnabled, Key.masterLimit,
                    "idleTimeoutSeconds", "selectedInputUID", "inputVolume"] {
            d.removeObject(forKey: key)
        }
    }
}
