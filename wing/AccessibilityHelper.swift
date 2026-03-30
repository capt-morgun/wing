import AppKit

enum AccessibilityHelper {
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func isInputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }
}
