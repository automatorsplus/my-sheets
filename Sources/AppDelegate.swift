import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var uiTestOut: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    /// `--render <file.xlsx> <picture.png>`: opens a workbook, saves a picture of its window, and quits.
    var render: (URL, URL)?
    var perfFile: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let out = uiTestOut {
            UITest.run(outDir: out)
        }
        if let f = perfFile { Perf.run(f) }
        if let (file, png) = render {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { doc, _, error in
                if let error { print("open error: \(error.localizedDescription)"); exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let w = (doc as? SheetDocument)?.controller?.window { Driver.capture(w, to: png) }
                    exit(0)
                }
            }
        }
    }

    var isNormalRun: Bool { uiTestOut == nil && render == nil && perfFile == nil }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { isNormalRun }

    /// Starting the app, or clicking its Dock icon with no windows open, shows Home rather than a blank workbook.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        HomeWindowController.show()
        AppDelegate.showsHomeWhenEmpty = true
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.quitting = true
        return .terminateNow
    }

    @objc func showHome(_ sender: Any?) { HomeWindowController.show(beside: NSApp.keyWindow) }

    static var showsHomeWhenEmpty = false
    static var quitting = false

    /// Closing the last workbook brings Home back, so there's always a way to pick another.
    static func workbookClosed() {
        guard showsHomeWhenEmpty, !quitting else { return }
        DispatchQueue.main.async {
            guard !quitting, HomeWindowController.current == nil, NSDocumentController.shared.documents.isEmpty else { return }
            HomeWindowController.show()
        }
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        }
        typealias C = SheetWindowController

        let app = sub("MySheets")
        add(app, "About MySheets", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Hide MySheets", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit MySheets", #selector(NSApplication.terminate(_:)), "q")

        let file = sub("File")
        add(file, "New Workbook", #selector(NSDocumentController.newDocument(_:)), "n")
        add(file, "Home", #selector(AppDelegate.showHome(_:)), "h", [.command, .shift])
        // AppKit adds Open Recent after Open… by itself.
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
        file.items.last?.isAlternate = true
        add(file, "Rename…", #selector(NSDocument.rename(_:)))
        add(file, "Move To…", #selector(NSDocument.move(_:)))
        // AppKit turns this into Revert To ▸ Last Opened, Last Saved, Browse All Versions…
        add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))

        let edit = sub("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Clear Contents", #selector(C.clearContents(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Delete Rows", #selector(C.deleteRows(_:)), "-", [.control])
        add(edit, "Delete Columns", #selector(C.deleteColumns(_:)))
        add(edit, "Delete Sheet", #selector(C.deleteSheet(_:)))

        let insert = sub("Insert")
        add(insert, "Rows Above", #selector(C.insertRows(_:)), "=", [.control, .shift])
        add(insert, "Columns to the Left", #selector(C.insertColumns(_:)))
        add(insert, "Cut or Copied Cells", #selector(C.insertCutCells(_:)))
        insert.addItem(.separator())
        add(insert, "Sheet", #selector(C.insertSheet(_:)))

        let format = sub("Format")
        add(format, "Bold", #selector(C.toggleBold(_:)), "b")
        add(format, "Italic", #selector(C.toggleItalic(_:)), "i")
        add(format, "Bigger Text", #selector(C.increaseFontSize(_:)), ">", [.command, .shift])
        add(format, "Smaller Text", #selector(C.decreaseFontSize(_:)), "<", [.command, .shift])
        format.addItem(.separator())
        add(format, "Fill with Colour", #selector(C.fillWithColour(_:)))
        add(format, "No Fill", #selector(C.noFill(_:)))
        format.addItem(.separator())
        add(format, "Row Height…", #selector(C.rowHeightDialog(_:)))
        add(format, "AutoFit Row Height", #selector(C.autofitRows(_:)))
        add(format, "Hide Rows", #selector(C.hideRows(_:)))
        add(format, "Unhide Rows", #selector(C.unhideRows(_:)))
        format.addItem(.separator())
        add(format, "Column Width…", #selector(C.columnWidthDialog(_:)))
        add(format, "AutoFit Column Width", #selector(C.autofitColumns(_:)))
        add(format, "Hide Columns", #selector(C.hideColumns(_:)))
        add(format, "Unhide Columns", #selector(C.unhideColumns(_:)))
        format.addItem(.separator())
        add(format, "Rename Sheet…", #selector(C.renameActiveSheet(_:)))

        let view = sub("View")
        add(view, "Zoom In", #selector(C.zoomIn(_:)), "=")
        add(view, "Zoom Out", #selector(C.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(C.actualSize(_:)), "0")

        let window = sub("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        return main
    }
}
