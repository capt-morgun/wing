import AppKit

struct SwitcherWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let axWindow: AXUIElement?
    let isMinimized: Bool
    let isHidden: Bool
    let spaceIndex: Int?  // 1-based Desktop number, nil = unknown/current
}

@Observable
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    var windows: [SwitcherWindow] = []
    var selectedIndex: Int = 0
    var isVisible: Bool = false

    // MRU tracking: ordered list of pids, most recent first
    private var mruOrder: [pid_t] = []

    // Persistent AX cache: wid → AXUIElement, kept alive across show() calls
    private var axCache: [UInt32: AXUIElement] = [:]

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appsChanged(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appsChanged(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Build initial cache
        DispatchQueue.global(qos: .userInitiated).async { self.refreshAXCache() }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        mruOrder.removeAll { $0 == pid }
        mruOrder.insert(pid, at: 0)
    }

    @objc private func appsChanged(_ note: Notification) {
        DispatchQueue.global(qos: .userInitiated).async { self.refreshAXCache() }
    }

    // Refresh AX cache for all running regular apps — runs on background thread
    // Uses allAXWindows() which combines standard + brute-force to get windows on ALL spaces
    private func refreshAXCache() {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        var newCache: [UInt32: AXUIElement] = [:]
        for app in runningApps {
            for win in allAXWindows(pid: app.processIdentifier) {
                guard let wid = cgWindowID(for: win) else { continue }
                newCache[wid] = win
            }
        }
        DispatchQueue.main.async { self.axCache = newCache }
    }

    func show(onReady: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInteractive).async {
            // Full refresh — allAXWindows covers current + other-Space windows
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
            }
            var freshCache: [UInt32: AXUIElement] = [:]
            for app in runningApps {
                for win in allAXWindows(pid: app.processIdentifier) {
                    guard let wid = cgWindowID(for: win) else { continue }
                    freshCache[wid] = win
                }
            }
            let windowList = self.fetchWindows(axCache: freshCache)
            DispatchQueue.main.async {
                self.axCache = freshCache
                self.windows = windowList
                self.selectedIndex = windowList.count > 1 ? 1 : 0
                self.isVisible = true
                onReady?()
            }
        }
    }

    func selectNext() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
    }

    func selectPrev() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
    }

    func confirm() {
        guard windows.indices.contains(selectedIndex) else {
            isVisible = false
            return
        }
        let win = windows[selectedIndex]
        isVisible = false
        DispatchQueue.global(qos: .userInteractive).async {
            self.activateWindow(win)
        }
    }

    func cancel() {
        isVisible = false
    }

    // MARK: - Private

    private func fetchWindows(axCache: [UInt32: AXUIElement]) -> [SwitcherWindow] {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        var appByPid: [pid_t: NSRunningApplication] = [:]
        for app in runningApps { appByPid[app.processIdentifier] = app }

        var mruRank: [pid_t: Int] = [:]
        for (i, pid) in mruOrder.enumerated() { mruRank[pid] = i }

        // Minimized state from AX cache (covers all spaces)
        var axMinimized: [UInt32: Bool] = [:]
        for (wid, axWin) in axCache {
            axMinimized[wid] = axBool(axWin, kAXMinimizedAttribute)
        }

        // CGWindowList: all windows on ALL spaces
        let cgOptions: CGWindowListOption = [.excludeDesktopElements]
        guard let cgList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        struct CGWin {
            let wid: UInt32
            let pid: pid_t
            let title: String
            let bounds: CGRect
        }

        var cgWins: [CGWin] = []
        for info in cgList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  appByPid[pid] != nil,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            guard bounds.width > 50, bounds.height > 50 else { continue }
            cgWins.append(CGWin(wid: wid, pid: pid, title: title, bounds: bounds))
        }

        let allWids = cgWins.map { $0.wid }
        let spaceMap = windowSpaceMap(for: allWids)
        // Keep only windows that CGS has assigned to a known Space.
        // Without this, background/system subwindows appear as duplicates.
        cgWins = cgWins.filter { spaceMap[$0.wid] != nil }

        var seen = Set<UInt32>()
        let sortedPids = cgWins.map { $0.pid }
            .reduce(into: [pid_t]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { mruRank[$0] ?? Int.max < mruRank[$1] ?? Int.max }

        var byPid: [pid_t: [CGWin]] = [:]
        for w in cgWins { byPid[w.pid, default: []].append(w) }

        var result: [SwitcherWindow] = []
        var pidsWithWindows = Set<pid_t>()

        for pid in sortedPids {
            guard let wins = byPid[pid] else { continue }
            let app = appByPid[pid]!
            pidsWithWindows.insert(pid)

            for w in wins {
                guard !seen.contains(w.wid) else { continue }
                seen.insert(w.wid)
                let axWin = axCache[w.wid]

                // Filter out background/auxiliary windows (tooltips, panels, overlays).
                // Only AXStandardWindow and AXDialog are real user-facing windows.
                // alt-tab-macos uses the same subrole check in WindowDiscriminator.
                if let ax = axWin {
                    var subroleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                       let subrole = subroleRef as? String,
                       subrole != kAXStandardWindowSubrole, subrole != kAXDialogSubrole {
                        continue
                    }
                }

                let isMin = axMinimized[w.wid] ?? false
                // Prefer AX title (works without Screen Recording, returns full window title)
                // fallback to CGWindowList title, then app name
                let axTitle = axWin.flatMap { axString($0, kAXTitleAttribute) }
                let title = axTitle?.isEmpty == false ? axTitle! : (w.title.isEmpty ? (app.localizedName ?? "") : w.title)
                result.append(SwitcherWindow(
                    windowID: w.wid,
                    pid: pid,
                    appName: app.localizedName ?? "",
                    windowTitle: title,
                    icon: app.icon,
                    axWindow: axWin,
                    isMinimized: isMin,
                    isHidden: app.isHidden,
                    spaceIndex: spaceMap[w.wid]
                ))
            }
        }

        // Remove windows whose title is just the app name if that app has other
        // windows with a real title. These are background/auxiliary windows
        // (e.g. Termius showing twice: "Termius" + "Termius - SFTP").
        let pidsWithRealTitle = Set(result.filter { $0.windowTitle != $0.appName }.map { $0.pid })
        return result.filter { $0.windowTitle != $0.appName || !pidsWithRealTitle.contains($0.pid) }
    }

    private func axBool(_ win: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attr as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private func axString(_ win: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attr as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    private func axSize(_ win: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &ref) == .success
        else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(ref as! AXValue, .cgSize, &sz)
        return sz
    }

    // Adapted from alt-tab-macos (https://github.com/lwouis/alt-tab-macos), GPL-3.0
    private func activateWindow(_ win: SwitcherWindow) {
        guard let app = NSRunningApplication(processIdentifier: win.pid) else { return }

        guard win.windowID != 0 else {
            app.activate(options: [])
            return
        }

        if app.isHidden { app.unhide() }

        if win.isMinimized, let axWin = win.axWindow {
            AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        var psn = ProcessSerialNumber()
        GetProcessForPID(win.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, win.windowID, 0x200)
        makeKeyWindow(&psn, win.windowID)
        if let axWin = win.axWindow {
            // kAXRaiseAction + _SLPSSetFrontProcessWithOptions together trigger the
            // Space switch animation when the window is on another Space (alt-tab-macos approach).
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        } else {
            // axWin not in AX cache (window on another Space not yet discovered by brute-force).
            // Fall back to standard activation — macOS handles the Space switch natively.
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // Ported from https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    // via alt-tab-macos (https://github.com/lwouis/alt-tab-macos), GPL-3.0
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }
}
