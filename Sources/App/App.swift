import AppKit
import SwiftUI

@main
struct SS2MP4App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ss2mp4", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ExportModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isExporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop exporting and quit?"
        alert.informativeText = "The export in progress will be stopped and its unfinished file removed. Finished exports are kept."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Exporting")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopForQuit()
    }
}
