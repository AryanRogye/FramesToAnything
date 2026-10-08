#if os(macOS)
import AppKit
import ApplicationServices
import IOKit.hidsystem

nonisolated enum MacMediaKeyController {
    static func togglePlayPause() {
        DispatchQueue.main.async {
            if !AXIsProcessTrusted() {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
            postPlayPause(state: 0xA)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35)) {
                postPlayPause(state: 0xB)
            }
        }
    }

    private static func postPlayPause(state: Int32) {
        let keyCode = Int32(NX_KEYTYPE_PLAY)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (state << 8)),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
#endif
