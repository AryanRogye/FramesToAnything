// swift-tools-version: 6.2
import PackageDescription

// Compile the actual sender policy in isolation so receiver-only JVM tests
// cannot hide another mismatch across the Mac/Fire TV protocol boundary.
let package = Package(
    name: "PlaybackPolicy",
    products: [.library(name: "PlaybackPolicy", targets: ["PlaybackPolicy"])],
    targets: [
        .target(
            name: "PlaybackPolicy",
            path: "macOSFramesToFireTV/macOS",
            exclude: ["FireTVTransport.swift", "macOSContentView.swift"],
            sources: ["ReceiverBufferPolicy.swift"]
        ),
        .testTarget(name: "PlaybackPolicyTests", dependencies: ["PlaybackPolicy"])
    ]
)
