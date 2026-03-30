# Wing

A lightweight window manager for macOS. Snap windows to precise positions, switch between open windows across all Spaces with a hold-and-release hotkey, and move any window to another Desktop — all with keyboard shortcuts.

<img src="assets/screenshot.png" width="320"/>

<img src="assets/demo.gif" width="640"/>

## Features

- **Window Switcher** — hold Mod+Tab to cycle through open windows across all Spaces
- Snap windows to halves, quarters, and eighths of the screen
- Center any window at a configurable size with a single shortcut
- Configurable split ratios (left/right width, top/bottom height)
- **Window Control** — maximize/restore, minimize, close windows via hotkeys
- **Move to Desktop** — send the active window to any Desktop with Mod+Number
- All hotkeys fully configurable in Settings
- Menu bar app — lives quietly in the background
- Launch at Login option in Settings

## Window Switcher

<img src="assets/screenshot2.png" width="260"/>

Hold your modifier key + Tab to open the switcher. Shows all open windows across all apps and all Spaces.

| Shortcut | Action |
|---|---|
| Mod + Tab | Open switcher / next window |
| ↑ / ↓ | Navigate the list |
| Release Mod | Switch to selected window |
| Escape | Cancel |

- Each window shows the Desktop number it belongs to
- If an app has multiple windows, each appears as a separate entry
- Switching to a window on another Space moves you there automatically

The Window Switcher can be enabled or disabled in Settings.

## Snap Shortcuts

Hold your chosen modifier key (Option, Command, or Control), then press arrow keys:

| Shortcut | Action |
|---|---|
| Mod + C | Center window (configurable size) |
| Mod + ← | Left half |
| Mod + → | Right half |
| Mod + ↑ | Top half |
| Mod + ↓ | Bottom half |
| Mod + ← + ↑ | Top left quarter |
| Mod + ← + ↓ | Bottom left quarter |
| Mod + → + ↑ | Top right quarter |
| Mod + → + ↓ | Bottom right quarter |
| ⇧ + Mod + ← + ↑ | Top left eighth |
| ⇧ + Mod + ← + ↓ | Bottom left eighth |
| ⇧ + Mod + → + ↑ | Top right eighth |
| ⇧ + Mod + → + ↓ | Bottom right eighth |

## Window Control

Configurable hotkeys for window management (defaults shown):

| Shortcut | Action |
|---|---|
| Mod + M | Maximize / Restore |
| Mod + D | Minimize all windows |
| Mod + H | Minimize active window |
| Mod + W | Close active window |

All keys can be changed in Settings. Window Control can be enabled or disabled independently.

## Move to Desktop

Press Mod+1 through Mod+9 to move the active window to the corresponding Desktop — without closing the app or losing any unsaved work.

**How it works:** macOS natively carries a dragged window to a new Space when you switch desktops during a drag. The app uses this behaviour:

1. Simulates holding the mouse button on the window's title bar
2. Switches to the target Desktop via a Ctrl+N keyboard shortcut
3. Releases the drag — the window is now on the target Desktop
4. Restores the window to its original position and size

### Requirements

**1. Mission Control keyboard shortcuts** must be enabled so the app can jump directly to the target Desktop in one keystroke.

Go to **System Settings → Keyboard → Keyboard Shortcuts → Mission Control** and enable **Switch to Desktop 1** through **Switch to Desktop N** (for however many Desktops you use).

<img src="assets/mission_control.png" width="480"/>

**2. Dock assignment** for the app being moved must be set to **Assign To → None** or **Assign To → This Desktop**. Right-click the app icon in the Dock → Options.

<img src="assets/dock-assign-none.png" width="320"/>

If the app is set to **All Desktops**, macOS will show it on every Space and the window will not move to a specific Desktop.

Requires Automation permission (prompted on first use) so the app can send keystrokes to System Events.

Move to Desktop can be enabled or disabled in Settings.

## Installation

Since the app is not notarized, macOS will block it on first launch. To open it:

1. Mount the DMG and drag **Wing.app** to Applications
2. Try to open it — macOS will show *"can't be opened because it is from an unidentified developer"*
3. Go to **System Settings → Privacy & Security**
4. Scroll down and click **"Open Anyway"**
5. Click **Open** in the confirmation dialog

Alternatively, run this command in Terminal after copying the app to Applications:
```bash
xattr -cr /Applications/Wing.app
```

## Requirements

- macOS 13+
- Accessibility permission
- Automation permission (for Move to Desktop)

---

[Русская версия](README.ru.md)
