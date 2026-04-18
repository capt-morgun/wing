import AppKit
import Carbon

final class TextSwitcher {
    static let shared = TextSwitcher()

    /// User-data value stamped on synthetic events so HotkeyManager can ignore them
    static let syntheticMarker: Int64 = 0x57494E47  // "WING"

    /// nspasteboard.org convention: mark items so clipboard managers (Paste, Raycast,
    /// Maccy, etc.) skip them and don't pollute the user's clipboard history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    struct LayoutInfo {
        let source: TISInputSource
        let name: String
        /// keycode → (char without shift, char with shift)
        let keycodeToChars: [UInt16: (lower: Character?, upper: Character?)]
    }

    struct BufferEntry {
        let keycode: UInt16
        let isShifted: Bool
    }

    private(set) var layouts: [LayoutInfo] = []

    /// Set to true while we are switching the layout ourselves, to skip the reload notification
    private var isOurOwnLayoutSwitch = false

    /// Keycodes typed in the current typing session (resets after transform or reset key)
    private var pendingBuffer: [BufferEntry] = []
    /// Keycodes saved after first transform, for re-cycling through layouts
    private var cycleBuffer: [BufferEntry]?
    /// Number of on-screen characters belonging to the last transformed block
    private var cycleScreenLength = 0
    /// Which layout index to transform to on the next trigger
    private var targetLayoutIndex = 0
    /// Layout index that was active when user started typing (to skip on first transform)
    private var typingLayoutIndex: Int?
    /// Last text we wrote to the screen — reference for cycle deduplication
    private var lastTransformedText: String = ""
    /// Text that was in the clipboard when the user pressed Cmd+V, so double-Shift
    /// can convert pasted-but-wrong-layout text without needing keycode history.
    private var pastedText: String?

    private let maxBuffer = 200

    private init() {
        reloadLayouts()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reloadLayouts),
            name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    @objc func reloadLayouts() {
        guard !isOurOwnLayoutSwitch else {
            NSLog("[TextSwitcher] Skipping reload (our own layout switch)")
            return
        }
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let rawList = TISCreateInputSourceList(filter, false) else { return }
        let list = rawList.takeRetainedValue() as! [TISInputSource]

        layouts = list.compactMap { source -> LayoutInfo? in
            guard
                let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName),
                let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
            let map = buildKeycodeMap(data: data)
            guard !map.isEmpty else { return nil }
            return LayoutInfo(source: source, name: name, keycodeToChars: map)
        }

        NSLog("[TextSwitcher] Layouts: \(layouts.map(\.name))")
    }

    // MARK: - Layout mapping via UCKeyTranslate

    private func buildKeycodeMap(data: Data) -> [UInt16: (Character?, Character?)] {
        var result: [UInt16: (Character?, Character?)] = [:]
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            let kbType = UInt32(LMGetKbdType())
            for keycode in UInt16(0)..<UInt16(128) {
                let lower = translateKey(layout: ptr, keycode: keycode, shift: false, kbType: kbType)
                let upper = translateKey(layout: ptr, keycode: keycode, shift: true, kbType: kbType)
                if lower != nil || upper != nil {
                    result[keycode] = (lower, upper)
                }
            }
        }
        return result
    }

    private func translateKey(
        layout: UnsafePointer<UCKeyboardLayout>,
        keycode: UInt16, shift: Bool, kbType: UInt32
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modState: UInt32 = shift ? 2 : 0
        let status = UCKeyTranslate(
            layout, keycode, UInt16(kUCKeyActionDown),
            modState, kbType, 1,
            &deadKeyState, 4, &length, &chars
        )
        guard status == noErr, length == 1, chars[0] > 31, chars[0] != 127 else { return nil }
        guard let scalar = Unicode.Scalar(chars[0]) else { return nil }
        return Character(scalar)
    }

    // MARK: - Layout switching

    private func currentLayoutIndex() -> Int {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return 0 }
        guard let namePtr = TISGetInputSourceProperty(current, kTISPropertyLocalizedName) else { return 0 }
        let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
        return layouts.firstIndex(where: { $0.name == name }) ?? 0
    }

    private func switchToLayout(_ index: Int) {
        guard index < layouts.count else { return }
        isOurOwnLayoutSwitch = true
        TISSelectInputSource(layouts[index].source)
        NSLog("[TextSwitcher] Switched to layout[%d]='%@'", index, layouts[index].name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isOurOwnLayoutSwitch = false
        }
    }

    /// Delays the layout switch by 150 ms so async paste events (Level 3) complete first.
    private func scheduleSwitchToLayout(_ index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.switchToLayout(index)
        }
    }

    // MARK: - Buffer management (called from HotkeyManager on every keyDown)

    func appendToBuffer(keycode: UInt16, isShifted: Bool) {
        pastedText = nil  // user is typing fresh — pasted context is stale
        if pendingBuffer.isEmpty {
            typingLayoutIndex = currentLayoutIndex()
            let idx = typingLayoutIndex!
            NSLog("[TextSwitcher] Typing started in layout[%d]='%@'",
                  idx, idx < layouts.count ? layouts[idx].name : "?")
        }
        if pendingBuffer.count >= maxBuffer { pendingBuffer.removeFirst() }
        pendingBuffer.append(BufferEntry(keycode: keycode, isShifted: isShifted))
        cycleBuffer = nil
        targetLayoutIndex = 0
        NSLog("[TextSwitcher] Buffer append keycode=%d shifted=%d bufLen=%d", keycode, isShifted ? 1 : 0, pendingBuffer.count)
    }

    /// Called when Cmd+V is detected. Snapshots the clipboard so that a subsequent
    /// double-Shift can convert the pasted text to the correct layout.
    func recordPaste() {
        clearBuffer()
        pastedText = NSPasteboard.general.string(forType: .string)
        NSLog("[TextSwitcher] Paste recorded: '%@'", pastedText ?? "(nil)")
    }

    func deleteFromBuffer() {
        if cycleBuffer != nil {
            cycleBuffer = nil
            targetLayoutIndex = 0
            NSLog("[TextSwitcher] Cycle mode exited (backspace)")
        }
        if !pendingBuffer.isEmpty {
            pendingBuffer.removeLast()
            NSLog("[TextSwitcher] Buffer delete, bufLen=%d", pendingBuffer.count)
        }
    }

    func clearBuffer() {
        if !pendingBuffer.isEmpty || cycleBuffer != nil {
            NSLog("[TextSwitcher] Buffer cleared (was %d pending, cycle=%@)",
                  pendingBuffer.count, cycleBuffer != nil ? "yes" : "no")
        }
        pendingBuffer.removeAll()
        cycleBuffer = nil
        cycleScreenLength = 0
        targetLayoutIndex = 0
        typingLayoutIndex = nil
        lastTransformedText = ""
        pastedText = nil
    }

    // MARK: - Trigger (called on double-Shift)

    func trigger() {
        guard layouts.count >= 2 else {
            NSLog("[TextSwitcher] Need at least 2 enabled keyboard layouts (have %d)", layouts.count)
            return
        }

        // Priority 1: AX selection (native apps)
        if handleSelectedTextTransform() {
            clearBuffer()   // stale keycodes no longer reflect on-screen text
            return
        }

        // Priority 2: AX safety check — if selection is visible via AX but transform failed, abort
        if let element = focusedAXElement(), activeSelectionExists(in: element) {
            NSLog("[TextSwitcher] Trigger aborted: active selection detected but AX transform failed")
            return
        }

        // Priority 3: AX-capable text element without selection — trust the typing buffer.
        // Skipping the clipboard probe here avoids "copy current line" side effects in
        // Xcode, editors, and browsers where Cmd+C without a selection grabs the whole
        // line or page URL and we'd paste that back in.
        if focusedIsAXTextElement() {
            runBufferTransform()
            return
        }

        // Priority 4: Cmd+C clipboard probe for non-AX apps (Electron, Terminal, etc.)
        triggerViaClipboardProbeOrBuffer()
    }

    /// True if the focused AX element supports the selected-text-range attribute —
    /// i.e. it's a text field/area where we can reliably detect selection via AX.
    private func focusedIsAXTextElement() -> Bool {
        guard let element = focusedAXElement() else { return false }
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &ref
        ) == .success
    }

    private func triggerViaClipboardProbeOrBuffer() {
        // If the user has typed recently, trust the buffer — don't probe the clipboard.
        // Cmd+C without a real selection can silently grab the current line / URL /
        // whatever the app decides, which we'd then re-paste as "selected text".
        if !pendingBuffer.isEmpty || cycleBuffer != nil {
            runBufferTransform()
            return
        }

        let pb = NSPasteboard.general
        let savedItems = snapshotPasteboard(pb)

        pb.clearContents()
        let baselineCount = pb.changeCount
        postSynth(src: nil, keycode: 8, down: true,  flags: .maskCommand)  // Cmd+C
        postSynth(src: nil, keycode: 8, down: false, flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }

            let copied = pb.string(forType: .string) ?? ""
            // changeCount only advances if Cmd+C actually wrote something after our clear.
            let clipboardChanged = pb.changeCount > baselineCount

            // Restore original clipboard before doing anything else
            self.restorePasteboard(pb, snapshot: savedItems)

            // Valid selection: non-empty, single-line, short enough to be a word/phrase
            if clipboardChanged && !copied.isEmpty && !copied.contains("\n") && copied.count <= 200,
               let (transformed, targetIdx) = self.transformChars(copied) {
                NSLog("[TextSwitcher] Clipboard probe selection '%@' → layout[%d]: '%@'",
                      copied, targetIdx, transformed)
                self.clearBuffer()
                self.pasteFromClipboard(transformed)
                self.scheduleSwitchToLayout(targetIdx)
                return
            }

            // No selection found — run normal buffer transform
            self.runBufferTransform()
        }
    }

    private func runBufferTransform() {
        if let cycle = cycleBuffer {
            // What's on screen right now = last transformed text. Pick the next layout
            // whose output differs meaningfully (avoids "Russian" vs "Russian — PC"
            // variants giving an almost identical cycle result).
            let (nextIdx, transformed) = findMeaningfullyDifferentLayout(
                buffer: cycle, from: targetLayoutIndex, reference: lastTransformedText
            )
            targetLayoutIndex = nextIdx
            let target = layouts[targetLayoutIndex]
            NSLog("[TextSwitcher] Re-cycle → layout[%d]='%@': delete %d, type '%@'",
                  targetLayoutIndex, target.name, cycleScreenLength, transformed)
            replaceText(deleteCount: cycleScreenLength, newText: transformed)
            cycleScreenLength = transformed.count
            lastTransformedText = transformed
            scheduleSwitchToLayout(targetLayoutIndex)
        } else if let pasted = pastedText {
            // User pasted text and then double-Shifted without typing anything.
            // Treat the pasted string as the source and convert it via character→layout map.
            guard let (transformed, targetIdx) = transformChars(pasted) else {
                NSLog("[TextSwitcher] Paste transform ignored — could not map characters")
                return
            }
            targetLayoutIndex = targetIdx
            NSLog("[TextSwitcher] Paste transform '%@' → layout[%d]: '%@'",
                  pasted, targetIdx, transformed)
            replaceText(deleteCount: pasted.count, newText: transformed)
            lastTransformedText = transformed
            pastedText = nil
            scheduleSwitchToLayout(targetIdx)
        } else {
            guard !pendingBuffer.isEmpty else {
                NSLog("[TextSwitcher] Trigger ignored — buffer is empty")
                return
            }

            let skipIndex = typingLayoutIndex ?? currentLayoutIndex()
            // On-screen text right now = what keycodes produce in the layout the user
            // typed in. Use that as reference so we skip near-duplicate target layouts.
            let typedText = transformBuffer(pendingBuffer, to: layouts[skipIndex])
            let (nextIdx, transformed) = findMeaningfullyDifferentLayout(
                buffer: pendingBuffer, from: skipIndex, reference: typedText
            )
            targetLayoutIndex = nextIdx
            let target = layouts[targetLayoutIndex]
            NSLog("[TextSwitcher] Transform %d chars → layout[%d]='%@': '%@'",
                  pendingBuffer.count, targetLayoutIndex, target.name, transformed)
            replaceText(deleteCount: pendingBuffer.count, newText: transformed)
            cycleBuffer = pendingBuffer
            cycleScreenLength = transformed.count
            lastTransformedText = transformed
            pendingBuffer.removeAll()
            scheduleSwitchToLayout(targetLayoutIndex)
        }
    }

    // MARK: - Selected text transform

    /// Returns true if there was a non-empty selection that was handled.
    private func handleSelectedTextTransform() -> Bool {
        guard let element = focusedAXElement() else {
            NSLog("[TextSwitcher] handleSelectedText: no focused AX element")
            return false
        }

        // Check range attribute (supported in most native apps)
        if let sel = selectionRange(in: element) {
            NSLog("[TextSwitcher] handleSelectedText: sel={loc=%d, len=%d}", sel.location, sel.length)
            guard sel.length > 0 else { return false }
        } else {
            NSLog("[TextSwitcher] handleSelectedText: range attribute unavailable, trying text attribute")
        }

        // Get the actual selected text (also works in apps that don't expose range)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let selectedText = ref as? String, !selectedText.isEmpty else {
            NSLog("[TextSwitcher] handleSelectedText: no selected text found")
            return false
        }

        NSLog("[TextSwitcher] Selected text detected: '%@' (%d chars)", selectedText, selectedText.count)

        guard let (transformed, targetIdx) = transformChars(selectedText) else { return false }
        targetLayoutIndex = targetIdx
        NSLog("[TextSwitcher] Selected → layout[%d]='%@': '%@'", targetIdx, layouts[targetIdx].name, transformed)

        // Selection is already made by the user — just replace it
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, transformed as CFString) == .success {
            NSLog("[TextSwitcher] Selection replaced via AX direct")
        } else {
            NSLog("[TextSwitcher] Selection replaced via clipboard paste")
            pasteFromClipboard(transformed)
        }
        scheduleSwitchToLayout(targetIdx)
        return true
    }

    /// Transforms a string by finding keycodes via the best-matching source layout.
    private func transformChars(_ text: String) -> (String, Int)? {
        guard layouts.count >= 2 else { return nil }

        // Find which layout maps the most characters (most likely the source layout)
        var bestSourceIdx = currentLayoutIndex()
        var bestCount = -1
        for (idx, layout) in layouts.enumerated() {
            let count = text.filter { charToKeycode($0, in: layout) != nil }.count
            if count > bestCount {
                bestCount = count
                bestSourceIdx = idx
            }
        }

        let targetIdx = (bestSourceIdx + 1) % layouts.count
        let source = layouts[bestSourceIdx]
        let target = layouts[targetIdx]

        let result = String(text.map { char -> Character in
            guard let (keycode, isShifted) = charToKeycode(char, in: source) else { return char }
            guard let (lower, upper) = target.keycodeToChars[keycode] else { return char }
            return isShifted ? (upper ?? lower ?? char) : (lower ?? char)
        })

        return (result, targetIdx)
    }

    private func charToKeycode(_ char: Character, in layout: LayoutInfo) -> (UInt16, Bool)? {
        for (keycode, (lower, upper)) in layout.keycodeToChars {
            if lower == char { return (keycode, false) }
            if upper == char { return (keycode, true) }
        }
        return nil
    }

    private func transformBuffer(_ entries: [BufferEntry], to layout: LayoutInfo) -> String {
        String(entries.map { entry -> Character in
            guard let (lower, upper) = layout.keycodeToChars[entry.keycode] else { return "?" }
            if entry.isShifted { return upper ?? lower ?? "?" }
            return lower ?? "?"
        })
    }

    /// Walks forward from `startIndex` and returns the first layout whose transform
    /// of `buffer` differs meaningfully from `reference` (< 70% character match).
    /// Falls back to the immediate next layout if every candidate is too similar.
    private func findMeaningfullyDifferentLayout(
        buffer: [BufferEntry], from startIndex: Int, reference: String
    ) -> (index: Int, transformed: String) {
        let fallbackIndex = (startIndex + 1) % layouts.count
        var idx = startIndex
        for _ in 0..<layouts.count {
            idx = (idx + 1) % layouts.count
            if idx == startIndex { break }
            let candidate = transformBuffer(buffer, to: layouts[idx])
            if similarityRatio(candidate, reference) < 0.7 {
                return (idx, candidate)
            }
        }
        return (fallbackIndex, transformBuffer(buffer, to: layouts[fallbackIndex]))
    }

    /// Fraction of positions where two equal-length strings share the same character.
    /// Returns 0 for mismatched lengths (shouldn't happen — transformBuffer preserves length).
    private func similarityRatio(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0.0 }
        let matches = zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
        return Double(matches) / Double(a.count)
    }

    // MARK: - Text replacement (3-level fallback)

    private func replaceText(deleteCount: Int, newText: String) {
        if replaceViaAXDirect(deleteCount: deleteCount, newText: newText) {
            NSLog("[TextSwitcher] Replaced via AX direct")
            return
        }
        // Skip AX-select+paste: in Terminal and similar apps the AX selection verify passes
        // but Cmd+V pastes at the readline cursor (not at the AX-selected scroll-buffer position),
        // causing the wrong text to stay and the correct text to be appended after it.
        // Backspace × N + paste works universally.
        NSLog("[TextSwitcher] Falling back to backspace + paste")
        replaceViaShiftSelectPaste(deleteCount: deleteCount, newText: newText)
    }

    /// Level 1: Set selection + kAXSelectedTextAttribute directly.
    /// After setting the range we verify it was actually honoured (some apps silently ignore it).
    private func replaceViaAXDirect(deleteCount: Int, newText: String) -> Bool {
        guard let element = focusedAXElement() else { return false }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        guard let sel = selectionRange(in: element), sel.location >= deleteCount else { return false }

        var replaceRange = CFRange(location: sel.location - deleteCount, length: deleteCount)
        guard let rangeVal = AXValueCreate(.cfRange, &replaceRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeVal) == .success
        else { return false }

        // Verify the selection was actually applied (Notes and some other apps ignore AX range sets)
        guard let verified = selectionRange(in: element), verified.length == deleteCount else {
            NSLog("[TextSwitcher] AX direct: selection verify failed, falling through")
            var restore = CFRange(location: sel.location, length: 0)
            if let rv = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rv)
            }
            return false
        }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFString) == .success
        else {
            var restore = CFRange(location: sel.location, length: 0)
            if let rv = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rv)
            }
            return false
        }
        return true
    }

    /// Level 2: Set selection range via AX + paste via clipboard.
    /// Same verification as Level 1.
    private func replaceViaAXSelectPaste(deleteCount: Int, newText: String) -> Bool {
        guard let element = focusedAXElement() else { return false }
        guard let sel = selectionRange(in: element), sel.location >= deleteCount else { return false }

        var replaceRange = CFRange(location: sel.location - deleteCount, length: deleteCount)
        guard let rangeVal = AXValueCreate(.cfRange, &replaceRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeVal) == .success
        else { return false }

        guard let verified = selectionRange(in: element), verified.length == deleteCount else {
            NSLog("[TextSwitcher] AX select+paste: selection verify failed, falling through")
            return false
        }

        pasteFromClipboard(newText)
        return true
    }

    /// Level 3: Backspace × N to delete, then paste via clipboard.
    /// Works in terminals (readline) and other apps where AX selection is not supported.
    private func replaceViaShiftSelectPaste(deleteCount: Int, newText: String) {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        writeTransientString(newText, to: pb)

        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<deleteCount {
            postSynth(src: src, keycode: 51, down: true)   // Backspace
            postSynth(src: src, keycode: 51, down: false)
        }

        // Give the app time to process every backspace before we paste.
        // Slow Electron/web apps can queue backspaces — adaptive delay scales with N.
        let beforePaste = max(0.05, Double(deleteCount) * 0.004)
        DispatchQueue.main.asyncAfter(deadline: .now() + beforePaste) { [weak self] in
            self?.postSynth(src: nil, keycode: 9, down: true,  flags: .maskCommand)  // Cmd+V
            self?.postSynth(src: nil, keycode: 9, down: false, flags: .maskCommand)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.restorePasteboard(pb, snapshot: saved)
            }
        }
    }

    // MARK: - AX helpers

    /// Returns true if there is a non-empty text selection in the element.
    /// Checks both the range attribute and the selected-text attribute (fallback for apps
    /// that expose text but not range, e.g. some Electron/non-native apps).
    private func activeSelectionExists(in element: AXUIElement) -> Bool {
        if let sel = selectionRange(in: element) {
            return sel.length > 0
        }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let text = ref as? String else { return false }
        return !text.isEmpty
    }

    private func focusedAXElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    /// Returns the current selection range (location = cursor/selection start, length = 0 if cursor only).
    private func selectionRange(in element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Clipboard paste helper

    private func pasteFromClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        writeTransientString(text, to: pb)

        postSynth(src: nil, keycode: 9, down: true,  flags: .maskCommand)  // Cmd+V
        postSynth(src: nil, keycode: 9, down: false, flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.restorePasteboard(pb, snapshot: saved)
        }
    }

    // MARK: - Pasteboard snapshot helpers

    /// Snapshot every (type, data) on every item so we can fully restore after a probe/paste.
    /// The previous implementation only grabbed `types.first`, silently dropping alternate
    /// representations (e.g. RTF alongside plain string).
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [[(String, Data)]] {
        pb.pasteboardItems?.map { item in
            item.types.compactMap { type -> (String, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
        } ?? []
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: [[(String, Data)]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (typeStr, data) in pairs {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// Writes a string to the pasteboard tagged with the nspasteboard.org "concealed"
    /// UTI so clipboard managers skip it and don't spam the user's history.
    private func writeTransientString(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        pb.writeObjects([item])
    }

    // MARK: - Synthetic event helper

    private func postSynth(src: CGEventSource?, keycode: UInt16, down: Bool, flags: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}
