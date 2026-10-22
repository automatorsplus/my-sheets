import AppKit
import UniformTypeIdentifiers

/// Where workbooks are kept, and which ones the Home tab lists.
enum Library {
    static let xlsxType = "org.openxmlformats.spreadsheetml.sheet"
    /// Posted after any workbook is saved, so Home can show the new time and picture.
    static let changed = Notification.Name("MySheetsWorkbookSaved")

    /// Where the New workbook box starts: the last folder chosen there, the Desktop at first.
    /// Workbooks made without the box (Duplicate) are saved here too.
    static var folder: URL = {
        if let p = UserDefaults.standard.string(forKey: "NewWorkbookFolder"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }()

    /// The UI test turns this off, so it leaves Open Recent and the remembered lists alone, and Home ignores them.
    static var keepsRecents = true

    /// Every folder a new workbook has been put in, starting with `folder`. Home lists the workbooks in all of them.
    static var folders: [URL] {
        var out = [folder]
        if keepsRecents {
            for p in UserDefaults.standard.stringArray(forKey: "WorkbookFolders") ?? [] { out.append(URL(fileURLWithPath: p, isDirectory: true)) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Remembers the folder chosen for a new workbook: the box starts there next time, and Home lists it.
    static func chose(folder dir: URL) {
        folder = dir
        guard keepsRecents else { return }
        UserDefaults.standard.set(dir.path, forKey: "NewWorkbookFolder")
        var list = UserDefaults.standard.stringArray(forKey: "WorkbookFolders") ?? []
        if !list.contains(dir.path) { list.append(dir.path) }
        UserDefaults.standard.set(list, forKey: "WorkbookFolders")
    }

    /// Remembers a workbook that was opened or saved, so Home can list it wherever it is.
    static func remember(_ url: URL) {
        guard keepsRecents, url.pathExtension.lowercased() == "xlsx" else { return }
        var list = UserDefaults.standard.stringArray(forKey: "KnownWorkbooks") ?? []
        guard list.first != url.path else { return }
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(300)), forKey: "KnownWorkbooks")
    }

    static func makeFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// 3 for "Book3" or "Book3.xlsx".
    static func bookNumber(_ name: String) -> Int? {
        let base = name.lowercased().hasSuffix(".xlsx") ? String(name.dropLast(5)) : name
        guard base.hasPrefix("Book"), let n = Int(base.dropFirst(4)), n > 0, !base.dropFirst(4).hasPrefix("0") else { return nil }
        return n
    }

    /// The lowest N that no "BookN" in the folder or open window is using.
    static func nextBookNumber() -> Int {
        var used = Set<Int>()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if let n = bookNumber(name) { used.insert(n) }
        }
        for case let d as SheetDocument in NSDocumentController.shared.documents {
            if let n = d.untitledNumber { used.insert(n) }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }

    /// `base.xlsx` in `dir`, or `base 2.xlsx`, `base 3.xlsx`… if that's taken.
    static func freeURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent(base + ".xlsx")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).xlsx")
            n += 1
        }
        return url
    }

    /// Where changes to a file MySheets can't fully keep go: "Name (MySheets).xlsx" beside it,
    /// or in the workbooks folder if that folder can't be written to.
    static func copyURL(for original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent + " (MySheets)"
        var dir = original.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            try? makeFolder()
            dir = folder
        }
        return freeURL(in: dir, base: base)
    }

    struct Entry: Equatable {
        let url: URL
        let name: String
        let modified: Date
        /// False for files elsewhere that were opened recently.
        let inFolder: Bool
    }

    private static func isTemporary(_ path: String) -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/var/folders/") || path.hasPrefix(tmp)
    }

    /// Every workbook in the folders, plus ones opened or saved elsewhere, newest first.
    static func entries() -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        func add(_ raw: URL, inFolder: Bool) {
            let u = raw.standardizedFileURL.resolvingSymlinksInPath()
            let name = u.lastPathComponent
            guard u.pathExtension.lowercased() == "xlsx", !name.hasPrefix("~$"), !name.hasPrefix("."),
                  !seen.contains(u.path), inFolder || !isTemporary(u.path),
                  let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true
            else { return }
            seen.insert(u.path)
            out.append(Entry(url: u, name: u.deletingPathExtension().lastPathComponent,
                             modified: v.contentModificationDate ?? .distantPast, inFolder: inFolder))
        }
        for dir in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
            for u in files { add(u, inFolder: true) }
        }
        if keepsRecents {
            for p in UserDefaults.standard.stringArray(forKey: "KnownWorkbooks") ?? [] { add(URL(fileURLWithPath: p), inFolder: false) }
            for u in NSDocumentController.shared.recentDocumentURLs { add(u, inFolder: false) }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// "Today at 14:32", "Yesterday at 09:10", "18 Oct 2026 at 16:05".
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }
}

/// Keeps Finder's Open Recent list free of test files, and makes sure typing that's still in a cell
/// is kept when the app quits.
final class SheetDocumentController: NSDocumentController {
    override func noteNewRecentDocumentURL(_ url: URL) {
        Library.remember(url)
        if Library.keepsRecents { super.noteNewRecentDocumentURL(url) }
    }

    /// For the UI test: answers the New workbook box (given the suggested file) without showing it.
    static var answerNewWorkbook: ((URL) -> URL?)?

    /// New workbook first asks for a name and a place, like Excel's Save box, then saves an empty workbook
    /// there and opens it. So it's a file you can see and double-click from the start, and it saves itself after.
    override func newDocument(_ sender: Any?) {
        let suggested = Library.freeURL(in: Library.folder, base: "Book\(Library.nextBookNumber())")
        if let answer = Self.answerNewWorkbook {
            if let url = answer(suggested) { create(at: url) }
            return
        }
        let panel = NSSavePanel()
        panel.title = "New workbook"
        panel.message = "Give your new workbook a name, and choose where to keep it."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = suggested.deletingPathExtension().lastPathComponent
        panel.directoryURL = Library.folder
        panel.allowedContentTypes = [UTType(Library.xlsxType)!]
        panel.isExtensionHidden = true
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.create(at: url)
        }
        if let w = NSApp.keyWindow, w.isVisible, w.attachedSheet == nil {
            panel.beginSheetModal(for: w, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func create(at url: URL) {
        Library.chose(folder: url.deletingLastPathComponent())
        // Choosing an open workbook's file in the box means starting it again empty.
        let path = url.resolvingSymlinksInPath().path
        documents.first { $0.fileURL?.resolvingSymlinksInPath().path == path }?.close()
        do {
            try XLSXWriter.write(Workbook.blank(), styles: StyleTable.blank(), theme: nil, date1904: false).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.extensionHidden: true], ofItemAtPath: url.path)
        } catch {
            NSApp.presentError(error)
            return
        }
        openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    private var sheetDocuments: [SheetDocument] { documents.compactMap { $0 as? SheetDocument } }

    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        finishAll {
            super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                         didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
        }
    }

    override func closeAllDocuments(withDelegate delegate: Any?, didCloseAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        finishAll {
            super.closeAllDocuments(withDelegate: delegate, didCloseAllSelector: didCloseAllSelector, contextInfo: contextInfo)
        }
    }

    /// Ends any typing, then gives new workbooks their files, before the usual quit or close-all goes ahead.
    private func finishAll(then next: @escaping () -> Void) {
        let docs = sheetDocuments
        for d in docs { d.controller?.commitEditing(refocus: false) }
        var waiting = docs.count
        guard waiting > 0 else { next(); return }
        for d in docs {
            d.fileAway { _ in
                waiting -= 1
                if waiting == 0 { next() }
            }
        }
    }
}
