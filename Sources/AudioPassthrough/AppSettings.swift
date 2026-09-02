import Foundation
import AppKit

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

/// How the idle countdown is shown in the menu bar.
enum CountdownStyle: String, CaseIterable {
    case rounded   // "5m" until under a minute, then "45s"
    case seconds   // classic "M:SS" clock, always exact seconds

    var title: String {
        switch self {
        case .rounded: return "Rounded (minutes, then seconds)"
        case .seconds: return "Exact (M:SS)"
        }
    }
}

/// Where/how the countdown appears in the menu bar.
enum TimerLayout: String, CaseIterable {
    case classic   // timer replaces the plug icon
    case compact   // plug icon stays; timer shown beside it at 50% size

    var title: String {
        switch self {
        case .classic: return "Replace icon with timer"
        case .compact: return "Timer beside icon (small)"
        }
    }
}

/// Preset colors for the menu-bar countdown text.
enum TimerColor: String, CaseIterable {
    case accent, white, red, green, orange, blue

    var title: String {
        switch self {
        case .accent: return "System accent"
        case .white:  return "White"
        case .red:    return "Red"
        case .green:  return "Green"
        case .orange: return "Orange"
        case .blue:   return "Blue"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .accent: return .controlAccentColor
        case .white:  return .labelColor
        case .red:    return .systemRed
        case .green:  return .systemGreen
        case .orange: return .systemOrange
        case .blue:   return .systemBlue
        }
    }
}

/// What the second button in the setup window does.
enum SetupCloseAction: String, CaseIterable {
    case quit       // "Close Application" — terminates the app
    case minimize   // "Minimize to Menu Bar" — just closes the setup window

    var title: String {
        switch self {
        case .quit:     return "Close Application"
        case .minimize: return "Minimize to Menu Bar"
        }
    }

    var buttonLabel: String { title }
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
        static let countdownStyle = "countdownStyle"
        static let timerLayout = "timerLayout"
        static let timerColor = "timerColor"
        static let timerTextScale = "timerTextScale"
        static let setupCloseAction = "setupCloseAction"
        static let showSetupAtLogin = "showSetupAtLogin"
    }

    /// Countdown text size as a percentage of the base size (default 100%).
    /// Stored 50…200 (percent); base sizes differ per layout.
    var timerTextScale: Int {
        get {
            if d.object(forKey: Key.timerTextScale) == nil { return 100 }
            return min(max(d.integer(forKey: Key.timerTextScale), 50), 200)
        }
        set { d.set(min(max(newValue, 50), 200), forKey: Key.timerTextScale) }
    }

    /// Countdown position/size in the menu bar. Defaults to classic.
    var timerLayout: TimerLayout {
        get { TimerLayout(rawValue: d.string(forKey: Key.timerLayout) ?? "") ?? .classic }
        set { d.set(newValue.rawValue, forKey: Key.timerLayout) }
    }

    /// Countdown text color. Defaults to accent.
    var timerColor: TimerColor {
        get { TimerColor(rawValue: d.string(forKey: Key.timerColor) ?? "") ?? .accent }
        set { d.set(newValue.rawValue, forKey: Key.timerColor) }
    }

    /// Which action the setup window's secondary button performs. Defaults to quit.
    var setupCloseAction: SetupCloseAction {
        get { SetupCloseAction(rawValue: d.string(forKey: Key.setupCloseAction) ?? "") ?? .quit }
        set { d.set(newValue.rawValue, forKey: Key.setupCloseAction) }
    }

    /// Whether to show the setup window when launched at login. Defaults to false
    /// (login launches start quietly without the setup window).
    var showSetupAtLogin: Bool {
        get { d.bool(forKey: Key.showSetupAtLogin) }
        set { d.set(newValue, forKey: Key.showSetupAtLogin) }
    }

    /// Menu-bar idle countdown display style. Defaults to rounded.
    var countdownStyle: CountdownStyle {
        get { CountdownStyle(rawValue: d.string(forKey: Key.countdownStyle) ?? "") ?? .rounded }
        set { d.set(newValue.rawValue, forKey: Key.countdownStyle) }
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
        for key in [Key.sliderType, Key.hidden, Key.engine, Key.boostEnabled,
                    Key.masterLimit, Key.countdownStyle, Key.timerLayout, Key.timerColor,
                    Key.timerTextScale, Key.setupCloseAction, Key.showSetupAtLogin,
                    "idleTimeoutSeconds", "selectedInputUID", "inputVolume"] {
            d.removeObject(forKey: key)
        }
    }
}
