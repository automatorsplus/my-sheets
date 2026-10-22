import AppKit

/// Typing inside a cell. In Enter mode (started by typing) the arrow keys finish the entry and move,
/// as in Excel; in Edit mode (double-click, F2 or Ctrl-U) they move the caret. F2 switches between them.
final class CellEditor: NSTextView {
    enum Mode { case enter, edit }

    weak var ctl: SheetWindowController?
    var mode = Mode.enter
    var addr = CellAddr(0, 0)
    var cellRect = NSRect.zero
    /// Matches the grid's text inset, so the text doesn't jump when editing starts.
    var padX: CGFloat = 3
    private var topPad: CGFloat = 0

    override var textContainerOrigin: NSPoint { NSPoint(x: padX, y: topPad) }

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection([.shift, .control, .option, .command])
        if e.keyCode == 120 && f.isEmpty {
            mode = mode == .enter ? .edit : .enter
            ctl?.updateMode()
            return
        }
        super.keyDown(with: e)
    }

    override func doCommand(by selector: Selector) {
        guard let ctl else { super.doCommand(by: selector); return }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch selector {
        case #selector(insertNewline(_:)): ctl.commitEditing(then: shift ? .enterUp : .enterDown)
        case #selector(insertTab(_:)): ctl.commitEditing(then: .tab)
        case #selector(insertBacktab(_:)): ctl.commitEditing(then: .backTab)
        case #selector(cancelOperation(_:)): ctl.cancelEditing()
        // Option-Return starts a new line inside the cell.
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)): insertText("\n", replacementRange: selectedRange())
        case #selector(moveUp(_:)) where mode == .enter: ctl.commitEditing(then: .arrow(-1, 0))
        case #selector(moveDown(_:)) where mode == .enter: ctl.commitEditing(then: .arrow(1, 0))
        case #selector(moveLeft(_:)) where mode == .enter: ctl.commitEditing(then: .arrow(0, -1))
        case #selector(moveRight(_:)) where mode == .enter: ctl.commitEditing(then: .arrow(0, 1))
        default: super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        fitToText()
        ctl?.editorTextChanged(string)
    }

    /// Grows to the right (and down for extra lines) as the text gets longer, like Excel's editor.
    func fitToText() {
        guard let lm = layoutManager, let tc = textContainer, let scroll = superview?.enclosingScrollView else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineH = lm.defaultLineHeight(for: font ?? .systemFont(ofSize: 13))
        let textH = max(used.height, lineH)
        // Sits at the bottom of the cell, where the grid draws text.
        topPad = max(0, cellRect.height - textH - padX / 3)
        let maxW = max(cellRect.width, scroll.documentVisibleRect.maxX - cellRect.minX - 2)
        let w = min(maxW, max(cellRect.width, ceil(used.width + padX * 2 + 8)))
        let h = max(cellRect.height, ceil(textH + topPad + 2))
        setFrameSize(NSSize(width: w, height: h))
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // Clicking somewhere else (the formula bar, a button, another window) keeps what was typed.
        if ok, let ctl, ctl.editor === self { DispatchQueue.main.async { ctl.commitIfStillEditing(self) } }
        return ok
    }

    // Cmd-Z while typing throws the typing away, as in Excel.
    @objc func undo(_ sender: Any?) { ctl?.cancelEditing() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return true }
        return super.validateMenuItem(item)
    }
}
