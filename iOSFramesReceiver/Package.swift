// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReceiverSafety",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReceiverSafety", path: "iOSFramesReceiver",
                exclude: ["iOSFramesReceiverApp.swift", "iOSReceiverView.swift",
                          "iOSMediaPlayer.swift", "PairingService.swift", "Info.plist", "Assets.xcassets"],
                sources: ["AudioTimelinePolicy.swift", "ReceiverControlAuthentication.swift"]),
        .testTarget(name: "ReceiverSafetyTests", dependencies: ["ReceiverSafety"])
    ]
)
