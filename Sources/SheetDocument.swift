import AppKit

/// "a", "a and b", "a, b and c".
func plainList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
}

@objc(SheetDocument)
final class SheetDocument: NSDocument {
    var workbook = Workbook.blank()
    var styles = StyleTable.blank()
    var theme: Data?
    var date1904 = false
    /// Things in the opened file that saving would lose. While there are any, changes go into a copy.
    var losses: [String] = []
    var hasFormulas = false
    weak var controller: SheetWindowController?

    /// The N in "BookN", while a new workbook has no file yet.
    private(set) var untitledNumber: Int?
    /// The original's name, once changes to a file MySheets can't fully keep have gone into a copy.
    private(set) var copiedFrom: String?
    /// Callbacks waiting for the save that gives this workbook its file.
    private var filingWaiters: [(Error?) -> Void]?
    private var filingQueued = false

    // Like Numbers and Pages, changes save themselves as you go, so closing never loses work.
    override class var autosavesInPlace: Bool { true }

    override var displayName: String! {
        get {
            if let u = fileURL { return u.deletingPathExtension().lastPathComponent }
            if untitledNumber == nil { untitledNumber = Library.nextBookNumber() }
            return "Book\(untitledNumber!)"
        }
        set { super.displayName = newValue }
    }

    override func makeWindowControllers() {
        let wc = SheetWindowController(document: self)
        controller = wc
        addWindowController(wc)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let loaded = try XLSXReader.read(data)
        workbook = loaded.workbook
        styles = loaded.styles
        theme = loaded.theme
        date1904 = loaded.date1904
        losses = loaded.losses
        hasFormulas = loaded.hasFormulas
    }

    /// Doesn't end typing in a cell, because autosaving runs while you type. Saving, closing and quitting end it first.
    override func data(ofType typeName: String) throws -> Data {
        XLSXWriter.write(workbook, styles: styles, theme: theme, date1904: date1904)
    }

    // MARK: Saving

    override func save(_ sender: Any?) { controller?.commitEditing(); super.save(sender) }
    override func saveAs(_ sender: Any?) { controller?.commitEditing(); super.saveAs(sender) }
    override func duplicate(_ sender: Any?) { controller?.commitEditing(); super.duplicate(sender) }

    /// A new workbook, or a file MySheets can't fully keep, that has changes. These can't just be saved in place.
    private var needsFiling: Bool { isDocumentEdited && (fileURL == nil || !losses.isEmpty) }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        // The first change gives the workbook a file straight away, so it's on the Home tab and nothing is lost.
        if needsFiling && !filingQueued {
            filingQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.filingQueued = false
                self?.fileAway { _ in }
            }
        }
    }

    /// Saves a new workbook into the workbooks folder as BookN, or a file MySheets can't fully keep as a copy
    /// beside it ("Name (MySheets)"), so from then on it saves itself in place like any other.
    func fileAway(_ done: @escaping (Error?) -> Void) {
        if filingWaiters != nil { filingWaiters!.append(done); return }
        guard needsFiling else { done(nil); return }
        let target: URL
        let original = fileURL
        if let original {
            target = Library.copyURL(for: original)
        } else {
            do { try Library.makeFolder() } catch { done(error); return }
            target = Library.freeURL(in: Library.folder, base: displayName)
        }
        filingWaiters = [done]
        save(to: target, ofType: fileType ?? Library.xlsxType, for: .saveAsOperation) { [weak self] error in
            guard let self else { return }
            if error == nil {
                if let original { self.copiedFrom = original.deletingPathExtension().lastPathComponent }
                self.untitledNumber = nil
                NSDocumentController.shared.noteNewRecentDocument(self)
                self.controller?.updateBanner()
            } else if let error {
                NSLog("MySheets couldn't save to \(target.path): \(error.localizedDescription)")
            }
            let waiters = self.filingWaiters ?? []
            self.filingWaiters = nil
            for w in waiters { w(error) }
        }
    }

    /// Before a window closes: keep what's being typed, and make sure a new workbook has its file.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        controller?.commitEditing(refocus: false)
        fileAway { _ in
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    /// Pressing Save on a file with parts MySheets can't keep asks for a name for a copy,
    /// and the original stays as it was.
    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if fileURL != nil && !losses.isEmpty {
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        } else {
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL != nil && !losses.isEmpty {
            savePanel.message = "MySheets can't keep this file's \(plainList(losses)), so save a copy. The original file stays as it is."
            let base = (fileURL!.deletingPathExtension().lastPathComponent)
            savePanel.nameFieldStringValue = base + " (MySheets).xlsx"
        } else if fileURL == nil {
            try? Library.makeFolder()
            savePanel.directoryURL = Library.folder
        }
        return true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        // Autosaving never writes over a file with parts MySheets can't keep, and puts new workbooks
        // in the workbooks folder rather than a hidden one.
        if (saveOperation == .autosaveInPlaceOperation || saveOperation == .autosaveElsewhereOperation) && needsFiling {
            fileAway { error in
                if error != nil && saveOperation == .autosaveElsewhereOperation {
                    // The folder can't be written to: keep the changes where the Mac keeps unsaved work.
                    super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
                } else {
                    completionHandler(error)
                }
            }
            return
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self {
                if saveOperation == .saveAsOperation, !self.losses.isEmpty {
                    // The copy now holds everything MySheets can show, so later saves can go straight into it.
                    self.losses = []
                    self.controller?.updateBanner()
                }
                if let u = self.fileURL { Library.remember(u) }
                NotificationCenter.default.post(name: Library.changed, object: self)
            }
            completionHandler(error)
        }
    }

    // MARK: Editing with undo

    /// Makes a change that Undo can take back. The whole workbook is the undo snapshot; its storage is
    /// shared until changed, so this is cheap.
    func edit(_ action: String, _ body: (inout Workbook) -> Void) {
        let before = workbook
        body(&workbook)
        registerUndo(back: before, action)
        controller?.documentChanged()
    }

    /// For changes already made live (dragging a row edge): records them as one step.
    func commit(_ action: String, before: Workbook) {
        registerUndo(back: before, action)
        controller?.documentChanged()
    }

    private func registerUndo(back old: Workbook, _ action: String) {
        let now = workbook
        guard let um = undoManager else { return }
        // Normally each mouse or key event is one undo step. Without that grouping (the UI test turns it off),
        // each change gets its own step.
        let own = !um.groupsByEvent && um.groupingLevel == 0
        if own { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { doc in
            doc.controller?.cancelEditing()
            doc.workbook = old
            doc.registerUndo(back: now, action)
            doc.controller?.documentChanged()
        }
        um.setActionName(action)
        if own { um.endUndoGrouping() }
    }
}
