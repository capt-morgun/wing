import AppKit

enum SnapRegion {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    // Eighths: Shift + quarter combo = half the quarter in both dimensions
    case topLeftEighth
    case topRightEighth
    case bottomLeftEighth
    case bottomRightEighth
    case center

    /// Returns the target frame in Accessibility API coordinates (top-left origin).
    func frame(on screen: NSScreen, settings: AppSettings) -> CGRect {
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first!.frame.height

        // Convert NSScreen visibleFrame (bottom-left origin) to AX coords (top-left origin)
        let axVisibleX = visible.origin.x
        let axVisibleY = primaryHeight - visible.origin.y - visible.height
        let visibleW = visible.width
        let visibleH = visible.height

        let leftW = visibleW * settings.leftWidthPercent / 100
        let rightW = visibleW * settings.rightWidthPercent / 100
        let topH = visibleH * settings.topHeightPercent / 100
        let bottomH = visibleH * settings.bottomHeightPercent / 100

        switch self {
        case .leftHalf:
            return CGRect(x: axVisibleX, y: axVisibleY, width: leftW, height: visibleH)
        case .rightHalf:
            return CGRect(x: axVisibleX + leftW, y: axVisibleY, width: rightW, height: visibleH)
        case .topHalf:
            return CGRect(x: axVisibleX, y: axVisibleY, width: visibleW, height: topH)
        case .bottomHalf:
            return CGRect(x: axVisibleX, y: axVisibleY + topH, width: visibleW, height: bottomH)
        case .topLeftQuarter:
            return CGRect(x: axVisibleX, y: axVisibleY, width: leftW, height: topH)
        case .topRightQuarter:
            return CGRect(x: axVisibleX + leftW, y: axVisibleY, width: rightW, height: topH)
        case .bottomLeftQuarter:
            return CGRect(x: axVisibleX, y: axVisibleY + topH, width: leftW, height: bottomH)
        case .bottomRightQuarter:
            return CGRect(
                x: axVisibleX + leftW, y: axVisibleY + topH, width: rightW, height: bottomH)
        case .topLeftEighth:
            return CGRect(x: axVisibleX, y: axVisibleY, width: leftW / 2, height: topH / 2)
        case .topRightEighth:
            return CGRect(
                x: axVisibleX + leftW + rightW / 2, y: axVisibleY, width: rightW / 2,
                height: topH / 2)
        case .bottomLeftEighth:
            return CGRect(
                x: axVisibleX, y: axVisibleY + topH + bottomH / 2, width: leftW / 2,
                height: bottomH / 2)
        case .bottomRightEighth:
            return CGRect(
                x: axVisibleX + leftW + rightW / 2, y: axVisibleY + topH + bottomH / 2,
                width: rightW / 2, height: bottomH / 2)
        case .center:
            let ratio = settings.centerWidthPercent / 100
            let w = visibleW * ratio
            let h = visibleH * ratio
            return CGRect(
                x: axVisibleX + (visibleW - w) / 2,
                y: axVisibleY + (visibleH - h) / 2,
                width: w, height: h)
        }
    }

    /// Resolve a set of held arrow keycodes into a SnapRegion.
    /// Arrow keycodes: Left=123, Right=124, Down=125, Up=126
    /// shiftHeld: when true, quarter combos map to eighths
    static func from(arrows: Set<Int64>, shiftHeld: Bool = false) -> SnapRegion? {
        let hasLeft = arrows.contains(123)
        let hasRight = arrows.contains(124)
        let hasDown = arrows.contains(125)
        let hasUp = arrows.contains(126)

        // Conflicting directions cancel out
        if hasLeft && hasRight { return nil }
        if hasUp && hasDown { return nil }

        switch (hasLeft, hasRight, hasUp, hasDown) {
        case (true, false, true, false): return shiftHeld ? .topLeftEighth : .topLeftQuarter
        case (true, false, false, true): return shiftHeld ? .bottomLeftEighth : .bottomLeftQuarter
        case (false, true, true, false): return shiftHeld ? .topRightEighth : .topRightQuarter
        case (false, true, false, true): return shiftHeld ? .bottomRightEighth : .bottomRightQuarter
        case (true, false, false, false): return .leftHalf
        case (false, true, false, false): return .rightHalf
        case (false, false, true, false): return .topHalf
        case (false, false, false, true): return .bottomHalf
        default: return nil
        }
    }
}
