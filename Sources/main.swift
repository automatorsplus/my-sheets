import AppKit

let arguments = CommandLine.arguments

// `MySheets --self-test [folder of .xlsx files]` checks the model and file format without a window.
if let i = arguments.firstIndex(of: "--self-test") {
    let folder = i + 1 < arguments.count ? arguments[i + 1] : nil
    exit(SelfTest.run(fixtures: folder))
}

let app = NSApplication.shared
// The first document controller made becomes the shared one.
_ = SheetDocumentController()
let delegate = AppDelegate()
if let i = arguments.firstIndex(of: "--ui-test"), i + 1 < arguments.count { delegate.uiTestOut = arguments[i + 1] }
if let i = arguments.firstIndex(of: "--perf"), i + 1 < arguments.count { delegate.perfFile = URL(fileURLWithPath: arguments[i + 1]) }
if let i = arguments.firstIndex(of: "--render"), i + 2 < arguments.count {
    delegate.render = (URL(fileURLWithPath: arguments[i + 1]), URL(fileURLWithPath: arguments[i + 2]))
}
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
