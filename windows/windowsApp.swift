import ServiceManagement
import SwiftUI

@main
struct windowsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        if !AccessibilityHelper.isGranted() {
            AccessibilityHelper.requestAccess()
        }

        HotkeyManager.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let gap: CGFloat = 2.5
            let lineWidth: CGFloat = 1.2
            let half = rect.width / 2

            // квадраты: top-left, top-right, bottom-left, bottom-right
            let rects: [NSRect] = [
                NSRect(x: 0,        y: half + gap / 2, width: half - gap / 2, height: half - gap / 2),
                NSRect(x: half + gap / 2, y: half + gap / 2, width: half - gap / 2, height: half - gap / 2),
                NSRect(x: 0,        y: 0,              width: half - gap / 2, height: half - gap / 2),
                NSRect(x: half + gap / 2, y: 0,              width: half - gap / 2, height: half - gap / 2),
            ]

            NSColor.black.setFill()
            NSColor.black.setStroke()

            for (i, r) in rects.enumerated() {
                let path = NSBezierPath(rect: r)
                path.lineWidth = lineWidth
                if i == 0 {
                    path.fill()
                } else {
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = makeMenuBarIcon()
        }

        buildMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMenu),
            name: .languageChanged,
            object: nil
        )
    }

    @objc private func rebuildMenu() {
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: t("Settings..."), action: #selector(openSettings), keyEquivalent: ","))

        let langItem = NSMenuItem(title: t("Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.rawValue, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang
            item.state = (AppSettings.shared.language == lang) ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: t("Quit"), action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? Language else { return }
        AppSettings.shared.language = lang
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Windows Settings"
            window.contentView = NSHostingView(rootView: ContentView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        HotkeyManager.shared.stop()
        NSApp.terminate(nil)
    }
}
