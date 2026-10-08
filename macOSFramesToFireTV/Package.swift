// swift-tools-version: 6.2
import PackageDescription

// Compile the actual sender policy in isolation so receiver-only JVM tests
// cannot hide another mismatch across the Mac/Fire TV protocol boundary.
let package = Package(
    name: "PlaybackPolicy",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PlaybackPolicy", targets: ["PlaybackPolicy"])],
    targets: [
        .target(
            name: "PlaybackPolicy",
            path: "macOSFramesToFireTV/macOS",
            exclude: ["Transport", "UI", "Streaming/MacStreamingModel.swift", "Streaming/MacStreamQuality.swift", "Streaming/CinemaAACEncoder.swift", "Streaming/CinemaQualityLevel.swift", "Security/TrustedReceiverStore.swift", "Captions/LiveCaptionExperiment.swift"],
            sources: ["Connection/ConnectionSessionPolicy.swift", "Captions/CaptionMode.swift", "Captions/CaptionRevisionState.swift", "Captions/CaptionAudioTap.swift", "Captions/CaptionAudioWindow.swift", "Streaming/ReceiverBufferPolicy.swift", "Security/ReceiverControlAuthentication.swift"]
        ),
        .testTarget(name: "PlaybackPolicyTests", dependencies: ["PlaybackPolicy"])
    ]
)
