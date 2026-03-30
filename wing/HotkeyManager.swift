import AppKit
import CoreGraphics

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heldArrows: Set<Int64> = []
    private var shiftHeld: Bool = false
    private var retryTimer: Timer?
    private var switcherActive: Bool = false

    // Arrow keycodes: Left=123, Right=124, Down=125, Up=126
    private static let arrowKeyCodes: Set<Int64> = [123, 124, 125, 126]
    // Tab keycode: 48
    private static let tabKeyCode: Int64 = 48
    // Number key virtual keycodes: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
    private static let numberKeyCodes: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10
    ]

    func start() {
        guard eventTap == nil else { return }

        // On macOS 10.15+, CGEventTap requires Input Monitoring permission
        let hasListenAccess = CGPreflightListenEventAccess()
        let hasTrusted = AXIsProcessTrusted()
        NSLog(
            "[HotkeyManager] AXIsProcessTrusted: \(hasTrusted), CGPreflightListenEventAccess: \(hasListenAccess)"
        )

        if !hasListenAccess {
            NSLog("[HotkeyManager] Requesting Input Monitoring access...")
            CGRequestListenEventAccess()
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: selfPtr
            )
        else {
            NSLog("[HotkeyManager] Failed to create event tap. Will retry every 3 seconds...")
            NSLog("[HotkeyManager] Please enable this app in:")
            NSLog("[HotkeyManager]   System Settings > Privacy & Security > Input Monitoring")
            NSLog("[HotkeyManager]   System Settings > Privacy & Security > Accessibility")
            startRetryTimer()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[HotkeyManager] Event tap started successfully!")
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        heldArrows.removeAll()
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            NSLog("[HotkeyManager] Retrying event tap creation...")
            self?.start()
        }
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent)
        -> Unmanaged<CGEvent>?
    {
        // Re-enable tap if it was disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // For flagsChanged, track modifier and shift state
        if type == .flagsChanged {
            let requiredFlag = AppSettings.shared.modifierKey.cgEventFlag
            if !event.flags.contains(requiredFlag) {
                heldArrows.removeAll()
                // Modifier released while switcher is open → confirm selection
                if switcherActive {
                    switcherActive = false
                    DispatchQueue.main.async {
                        WindowSwitcherPanel.shared.hide()
                        WindowSwitcher.shared.confirm()
                    }
                }
            }
            shiftHeld = event.flags.contains(.maskShift)
            return Unmanaged.passUnretained(event)
        }

        // Only process keyDown / keyUp from here
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let requiredFlag2 = AppSettings.shared.modifierKey.cgEventFlag
        guard event.flags.contains(requiredFlag2) else {
            return Unmanaged.passUnretained(event)
        }

        // Modifier + Tab = window switcher (next)
        if keyCode == Self.tabKeyCode && type == .keyDown && AppSettings.shared.windowSwitcherEnabled {
            DispatchQueue.main.async {
                if !self.switcherActive {
                    self.switcherActive = true
                    WindowSwitcherPanel.shared.show()
                } else {
                    WindowSwitcher.shared.selectNext()
                }
            }
            return nil
        }

        // Arrow keys while switcher is active
        if switcherActive && type == .keyDown {
            if keyCode == 125 {  // Down
                DispatchQueue.main.async { WindowSwitcher.shared.selectNext() }
                return nil
            }
            if keyCode == 126 {  // Up
                DispatchQueue.main.async { WindowSwitcher.shared.selectPrev() }
                return nil
            }
        }

        // Escape cancels switcher
        if keyCode == 53 && type == .keyDown && switcherActive {
            switcherActive = false
            DispatchQueue.main.async {
                WindowSwitcherPanel.shared.hide()
                WindowSwitcher.shared.cancel()
            }
            return nil
        }

        // Window Control hotkeys
        if AppSettings.shared.windowControlEnabled && type == .keyDown {
            let s = AppSettings.shared
            let actions: [(String, () -> Void)] = [
                (s.controlKeyMaximize,      { WindowManager.maximizeFocusedWindow() }),
                (s.controlKeyMinimizeAll,   { WindowManager.minimizeAllWindows() }),
                (s.controlKeyMinimizeActive,{ WindowManager.minimizeActiveWindow() }),
                (s.controlKeyCloseActive,   { WindowManager.closeActiveWindow() }),
                (s.controlKeyCenter,        { WindowManager.centerFocusedWindow() }),
            ]
            for (letter, action) in actions {
                if let code = AppSettings.keyCode(for: letter), keyCode == code {
                    DispatchQueue.main.async { action() }
                    return nil
                }
            }
        }

        // Modifier + number = move focused window to Desktop N
        if AppSettings.shared.moveToDesktopEnabled && type == .keyDown,
           let desktopIndex = Self.numberKeyCodes[keyCode] {
            NSLog("[HotkeyManager] Number key detected: keyCode=\(keyCode), desktop=\(desktopIndex)")
            DispatchQueue.main.async {
                WindowManager.moveFocusedWindowToDesktop(desktopIndex)
            }
            return nil
        }

        // Only care about arrow keys
        guard Self.arrowKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            heldArrows.insert(keyCode)

            if let region = SnapRegion.from(arrows: heldArrows, shiftHeld: shiftHeld) {
                WindowManager.snapFocusedWindow(to: region)
            }

            // Consume the event
            return nil

        } else if type == .keyUp {
            heldArrows.remove(keyCode)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type: type, event: event)
}
