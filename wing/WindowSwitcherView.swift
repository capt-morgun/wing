import SwiftUI

struct WindowSwitcherView: View {
    @State private var switcher = WindowSwitcher.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(switcher.windows.enumerated()), id: \.offset) { index, win in
                        row(for: win, index: index)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: switcher.selectedIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .frame(width: 420)
        .frame(maxHeight: min(CGFloat(switcher.windows.count) * 44 + 8, 500))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.switcherBgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }

    private var switcherFont: Font {
        let size = settings.switcherFontSize
        let name = settings.switcherFontName
        if name.isEmpty, let _ = NSFont(name: name, size: size) { }
        if !name.isEmpty, let _ = NSFont(name: name, size: size) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .regular)
    }

    // Show full window title as-is (includes "project — file.swift", "Telegram @ user", etc.)
    // Fall back to app name only if title is empty
    private func rowLabel(_ win: SwitcherWindow) -> String {
        win.windowTitle.isEmpty ? win.appName : win.windowTitle
    }

    @ViewBuilder
    private func row(for win: SwitcherWindow, index: Int) -> some View {
        let isSelected = index == switcher.selectedIndex

        HStack(spacing: 10) {
            // App icon
            if let icon = win.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 28, height: 28)
            }

            // Window label
            Text(rowLabel(win))
                .font(switcherFont)
                .foregroundColor(settings.switcherFontColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Desktop number badge — rounded rect with number
            if let spaceIdx = win.spaceIndex {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: 22, height: 18)
                    Text("\(spaceIdx)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            WindowSwitcher.shared.selectedIndex = index
            WindowSwitcher.shared.confirm()
        }
    }
}
