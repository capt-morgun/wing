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

    // Recently used window IDs (by windowID), most recent first.
    // Tracks specific windows, not just apps — needed when an app has multiple windows.
    private var recentWindowIDs: [CGWindowID] = []

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
        // Pre-warm: build AX cache + window list so first Tab press is instant
        DispatchQueue.global(qos: .userInitiated).async { self.fullRefresh() }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        mruOrder.removeAll { $0 == pid }
        mruOrder.insert(pid, at: 0)

        // Track the specific focused window of this app
        let appEl = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let axWin = ref,
           let wid = cgWindowID(for: axWin as! AXUIElement), wid != 0 {
            trackWindow(wid)
        }
    }

    private func trackWindow(_ wid: CGWindowID) {
        recentWindowIDs.removeAll { $0 == wid }
        recentWindowIDs.insert(wid, at: 0)
        if recentWindowIDs.count > 100 { recentWindowIDs.removeLast() }
    }

    @objc private func appsChanged(_ note: Notification) {
        DispatchQueue.global(qos: .userInitiated).async { self.fullRefresh() }
    }

    /// Full AX scan (standard + brute-force) — runs on background thread.
    /// Used at startup and when apps launch/terminate to keep the cache warm.
    private func fullRefresh() {
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
        let windowList = self.fetchWindows(axCache: newCache)
        DispatchQueue.main.async {
            self.axCache = newCache
            // Only update windows if switcher is not visible (don't disrupt navigation)
            if !self.isVisible {
                self.windows = windowList
            }
        }
    }

    func show(onReady: (() -> Void)? = nil) {
        // Fast path: use existing cache + standard AX only (no brute-force).
        // Brute-force results from init/appsChanged are already in axCache.
        DispatchQueue.global(qos: .userInteractive).async {
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
            }
            // Lightweight refresh: standard AX for current-space windows, merged with
            // existing cache (which has brute-force results for other-space windows).
            var freshCache = self.axCache
            for app in runningApps {
                let appEl = AXUIElementCreateApplication(app.processIdentifier)
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
                   let wins = ref as? [AXUIElement] {
                    for win in wins {
                        guard let wid = cgWindowID(for: win) else { continue }
                        freshCache[wid] = win
                    }
                }
            }
            let windowList = self.fetchWindows(axCache: freshCache)
            DispatchQueue.main.async {
                let wasVisible = self.isVisible
                self.axCache = freshCache

                if wasVisible {
                    // Background refresh while user is navigating — preserve selection
                    let prevID = self.windows.indices.contains(self.selectedIndex)
                        ? self.windows[self.selectedIndex].windowID : 0
                    self.windows = windowList
                    if let newIdx = windowList.firstIndex(where: { $0.windowID == prevID }) {
                        self.selectedIndex = newIdx
                    } else if self.selectedIndex >= windowList.count {
                        self.selectedIndex = max(0, windowList.count - 1)
                    }
                } else {
                    self.windows = windowList
                    self.selectedIndex = self.indexOfPreviousWindow()
                }

                self.isVisible = true
                onReady?()
            }
        }
    }

    /// Returns the index of the most recently used window that doesn't belong
    /// to the currently frontmost app. Uses recentWindowIDs to find the exact
    /// window (not just any window of that app), which matters when an app
    /// has multiple windows open.
    func indexOfPreviousWindow() -> Int {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // Walk recent history to find the most recently used non-current window
        for wid in recentWindowIDs {
            if let idx = windows.firstIndex(where: { $0.windowID == wid && $0.pid != frontPid }) {
                return idx
            }
        }
        // Fallback: first window of any other app
        return windows.firstIndex(where: { $0.pid != frontPid }) ?? 0
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
        trackWindow(win.windowID)
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
                } else {
                    // No AX entry — likely a background subwindow missed by brute-force.
                    // Only keep it if it has a real title from CGWindowList (not empty),
                    // otherwise it's almost certainly an auxiliary/invisible window.
                    if w.title.isEmpty { continue }
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
        var raised = false
        if let axWin = win.axWindow {
            // kAXRaiseAction + _SLPSSetFrontProcessWithOptions together trigger the
            // Space switch animation when the window is on another Space (alt-tab-macos approach).
            let err = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            raised = (err == .success)
            if !raised {
                NSLog("[WindowSwitcher] AXRaise failed (%d) for wid=%u, falling back", err.rawValue, win.windowID)
            }
        }
        if !raised {
            // axWin not in AX cache or stale — fall back to standard activation.
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
