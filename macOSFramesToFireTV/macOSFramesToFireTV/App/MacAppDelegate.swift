import AppKit

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = MacStreamingModel()
    private var isConfirmingQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isConfirmingQuit else { return .terminateCancel }
        isConfirmingQuit = true
        defer { isConfirmingQuit = false }

        let alert = AlertMaker.makeAlert(
            messageText: "Quit Frames to Fire TV?",
            informativeText: "Are you sure you want to quit? This will stop any active streaming and remove the app from the menu bar.",
            style: .warning,
            buttons: ["Cancel", "Quit"]
        )
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        sender.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }
        model.stop()
        return .terminateNow
    }
}
