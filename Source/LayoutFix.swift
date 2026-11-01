import AppKit
import Carbon

// 4.3.0 — fixing text typed in the wrong layout, like Punto Switcher.
// ⌃⌥L: the selected text (or, with nothing selected, the word before the
// cursor) is copied, converted, pasted back, the keyboard switches to the
// right layout, and the clipboard gets its old contents back.
// Needs «Универсальный доступ» (it already does), works where ⌘C/⌘V work.
final class LayoutFixer {
    var onResult: ((_ toRussian: Bool) -> Void)?
    var onNothing: (() -> Void)?
    var pauseClipboardWatch: ((TimeInterval) -> Void)?
    private var busy = false

    func run() {
        guard !busy else { return }
        busy = true
        pauseClipboardWatch?(2.5)
        waitForModifiersReleased(tries: 20) { [weak self] in self?.copySelection(selectWordFirst: false) }
    }

    // The hot key's ⌃⌥ must be up, or ⌘C would arrive as ⌃⌥⌘C.
    private func waitForModifiersReleased(tries: Int, then work: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
        if held.isEmpty || tries == 0 { work(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForModifiersReleased(tries: tries - 1, then: work)
        }
    }

    private func copySelection(selectWordFirst: Bool) {
        let board = NSPasteboard.general
        let saved = Self.snapshot(board)
        let before = board.changeCount
        if selectWordFirst { Self.press(UInt16(kVK_LeftArrow), [.maskAlternate, .maskShift]) }
        Self.press(UInt16(kVK_ANSI_C), [.maskCommand])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard board.changeCount != before, let text = board.string(forType: .string),
                  !text.isEmpty, text.count <= 2000 else {
                if !selectWordFirst {
                    // Nothing selected: take the word before the cursor.
                    self.copySelection(selectWordFirst: true)
                } else {
                    self.finish(restoring: saved)
                    self.onNothing?()
                }
                return
            }
            let result = LayoutConverter.convert(text)
            guard result.text != text else { self.finish(restoring: saved); self.onNothing?(); return }
            board.clearContents()
            board.setString(result.text, forType: .string)
            Self.press(UInt16(kVK_ANSI_V), [.maskCommand])
            Self.selectLayout(russian: result.toRussian)
            self.onResult?(result.toRussian)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.finish(restoring: saved) }
        }
    }

    private func finish(restoring saved: [[NSPasteboard.PasteboardType: Data]]) {
        Self.restore(saved, to: NSPasteboard.general)
        busy = false
    }

    private static func press(_ key: UInt16, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
    }

    // Switches the keyboard to a Russian or English layout, if one is enabled.
    private static func selectLayout(russian: Bool) {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        let wanted = russian ? "ru" : "en"
        for source in list {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
            let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
            if languages.first == wanted {
                TISSelectInputSource(source)
                return
            }
        }
    }
}
