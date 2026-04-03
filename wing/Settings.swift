import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

enum ModifierKey: String, CaseIterable, Identifiable {
    case option = "Option"
    case command = "Command"
    case control = "Control"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        }
    }

    var cgEventFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var modifierKey: ModifierKey {
        didSet { UserDefaults.standard.set(modifierKey.rawValue, forKey: "modifierKey") }
    }

    var leftWidthPercent: Double {
        didSet { UserDefaults.standard.set(leftWidthPercent, forKey: "leftWidthPercent") }
    }

    var topHeightPercent: Double {
        didSet { UserDefaults.standard.set(topHeightPercent, forKey: "topHeightPercent") }
    }

    var rightWidthPercent: Double { 100 - leftWidthPercent }
    var bottomHeightPercent: Double { 100 - topHeightPercent }

    var windowSwitcherEnabled: Bool {
        didSet { UserDefaults.standard.set(windowSwitcherEnabled, forKey: "windowSwitcherEnabled") }
    }

    var windowControlEnabled: Bool {
        didSet { UserDefaults.standard.set(windowControlEnabled, forKey: "windowControlEnabled") }
    }

    var controlKeyMaximize: String {
        didSet { UserDefaults.standard.set(controlKeyMaximize, forKey: "controlKeyMaximize") }
    }

    var controlKeyMinimizeAll: String {
        didSet { UserDefaults.standard.set(controlKeyMinimizeAll, forKey: "controlKeyMinimizeAll") }
    }

    var controlKeyMinimizeActive: String {
        didSet { UserDefaults.standard.set(controlKeyMinimizeActive, forKey: "controlKeyMinimizeActive") }
    }

    var controlKeyCloseActive: String {
        didSet { UserDefaults.standard.set(controlKeyCloseActive, forKey: "controlKeyCloseActive") }
    }

    var controlKeyCenter: String {
        didSet { UserDefaults.standard.set(controlKeyCenter, forKey: "controlKeyCenter") }
    }

    var centerWidthPercent: Double {
        didSet { UserDefaults.standard.set(centerWidthPercent, forKey: "centerWidthPercent") }
    }

    var moveToDesktopEnabled: Bool {
        didSet { UserDefaults.standard.set(moveToDesktopEnabled, forKey: "moveToDesktopEnabled") }
    }

    var textSwitcherEnabled: Bool {
        didSet { UserDefaults.standard.set(textSwitcherEnabled, forKey: "textSwitcherEnabled") }
    }

    var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: "modifierKey"),
            let key = ModifierKey(rawValue: raw)
        {
            modifierKey = key
        } else {
            modifierKey = .option
        }

        let savedLeft = defaults.double(forKey: "leftWidthPercent")
        leftWidthPercent = savedLeft > 0 ? savedLeft : 50

        let savedTop = defaults.double(forKey: "topHeightPercent")
        topHeightPercent = savedTop > 0 ? savedTop : 50

        windowSwitcherEnabled = defaults.object(forKey: "windowSwitcherEnabled") as? Bool ?? true

        windowControlEnabled = defaults.object(forKey: "windowControlEnabled") as? Bool ?? true
        controlKeyMaximize = defaults.string(forKey: "controlKeyMaximize") ?? "M"
        controlKeyMinimizeAll = defaults.string(forKey: "controlKeyMinimizeAll") ?? "D"
        controlKeyMinimizeActive = defaults.string(forKey: "controlKeyMinimizeActive") ?? "H"
        controlKeyCloseActive = defaults.string(forKey: "controlKeyCloseActive") ?? "W"
        controlKeyCenter = defaults.string(forKey: "controlKeyCenter") ?? "C"
        let savedCenter = defaults.double(forKey: "centerWidthPercent")
        centerWidthPercent = savedCenter > 0 ? savedCenter : 60

        moveToDesktopEnabled = defaults.object(forKey: "moveToDesktopEnabled") as? Bool ?? true

        textSwitcherEnabled = defaults.object(forKey: "textSwitcherEnabled") as? Bool ?? true

        if let raw = defaults.string(forKey: "language"),
           let lang = Language(rawValue: raw) {
            language = lang
        } else {
            language = .english
        }
    }

    // Maps single uppercase letter to its Carbon virtual keycode
    static func keyCode(for letter: String) -> Int64? {
        let map: [String: Int64] = [
            "A": 0,  "S": 1,  "D": 2,  "F": 3,  "H": 4,  "G": 5,
            "Z": 6,  "X": 7,  "C": 8,  "V": 9,  "B": 11, "Q": 12,
            "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
            "O": 31, "U": 32, "I": 34, "P": 35, "L": 37,
            "J": 38, "K": 40, "N": 45, "M": 46,
        ]
        return map[letter.uppercased()]
    }
}
