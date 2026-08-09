//
//  SampleHandler.swift
//  FireTVBroadcast
//
//  Created by Aryan Rogye on 7/25/26.
//

import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var transport: BroadcastTransport?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let configuration = BroadcastConfiguration.load() else {
            finishBroadcastWithError(
                BroadcastError(
                    "Open iOS Frames to Fire TV, select a receiver, and enter its current code first."
                )
            )
            return
        }

        let transport = BroadcastTransport(configuration: configuration)
        transport.onFailure = { [weak self] message in
            self?.finishBroadcastWithError(BroadcastError(message))
        }
        self.transport = transport
        transport.start()
    }

    override func broadcastPaused() {
        transport?.isPaused = true
    }

    override func broadcastResumed() {
        transport?.isPaused = false
    }

    override func broadcastFinished() {
        transport?.stop()
        transport = nil
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        transport?.send(sampleBuffer, type: sampleBufferType)
    }
}

private struct BroadcastError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
