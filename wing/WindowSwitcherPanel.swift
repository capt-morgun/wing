import AppKit
import SwiftUI

final class WindowSwitcherPanel {
    static let shared = WindowSwitcherPanel()

    private var panel: NSPanel?

    private init() {}

    func show() {
        // Destroy old panel to avoid stale windows floating between spaces
        panel?.orderOut(nil)
        panel = nil

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .popUpMenu: 2nd highest level, appears above all app windows.
        // .screenSaver would be higher but breaks drag-and-drop over the panel.
        // alt-tab-macos uses the same level.
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.transient, .fullScreenAuxiliary]

        let view = NSHostingView(rootView: WindowSwitcherView())
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        p.contentView = view
        panel = p

        // If we have a window list from a previous call, show immediately —
        // SwiftUI will re-render in place when fresh data arrives.
        // On the very first call windows is empty, so we wait for data.
        if WindowSwitcher.shared.windows.isEmpty {
            // First open before background pre-warm finished — wait for data
            WindowSwitcher.shared.show { [weak self] in
                self?.reposition()
                self?.panel?.orderFrontRegardless()
            }
        } else {
            // Cached data available — show instantly, refresh in background.
            // Pre-select the first window that isn't the current frontmost app.
            // Uses live frontmostApplication so it's correct even if mruOrder is stale.
            WindowSwitcher.shared.selectedIndex = WindowSwitcher.shared.indexOfPreviousWindow()
            reposition()
            panel?.orderFrontRegardless()
            // No reposition callback: avoids visual "jump" when fresh data arrives
            WindowSwitcher.shared.show()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func reposition() {
        guard let panel else { return }
        // Size to fit content first
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: 280, height: 200)
        let panelSize = CGSize(width: fittingSize.width, height: fittingSize.height)

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let origin = CGPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }
}
