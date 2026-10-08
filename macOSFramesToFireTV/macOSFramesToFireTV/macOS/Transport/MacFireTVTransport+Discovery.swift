#if os(macOS)
import Foundation
import OSLog
import Network
import SnapCore

/// Receiver discovery, outgoing/direct connections, and reverse connection setup.
/// This extension uses the same transport state and queues; it creates no new pipeline.
extension MacFireTVTransport {
    nonisolated func startDiscovery() {
        networkQueue.async { [weak self] in
            guard let self, serverRunning else { return }
            browserRetry?.cancel()
            browser?.cancel()
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjour(type: "_iosfiretv._tcp", domain: nil),
                using: parameters
            )
            self.browser = browser
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, browser === self.browser else { return }
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    macTransportLogger.warning("Receiver discovery failed: \(error.localizedDescription)")
                    browser.cancel()
                    self.browser = nil
                    let retry = DispatchWorkItem { [weak self] in self?.startDiscovery() }
                    browserRetry = retry
                    networkQueue.asyncAfter(deadline: .now() + 3, execute: retry)
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, browser === self.browser else { return }
                let devices = results.compactMap { result -> MacFireTVDevice? in
                    guard case .service(let name, _, _, _) = result.endpoint else {
                        return nil
                    }
                    let receiverID = Self.txtValue("id", from: result)
                        ?? TrustedReceiverStore.receiverID(forServiceName: name)
                    return MacFireTVDevice(
                        id: receiverID ?? String(describing: result.endpoint),
                        name: name,
                        endpoint: result.endpoint,
                        receiverID: receiverID
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.publish(devices)
            }
            browser.start(queue: networkQueue)
        }
    }

    nonisolated func connect(to device: MacFireTVDevice, code: String) {
        waitForReceiver(device: device, code: code)
    }

    /// Pairing authorizes one receiver; it never creates an outgoing Mac socket.
    nonisolated func waitForFireTV(code: String) {
        waitForReceiver(device: nil, code: code)
    }

    nonisolated func waitForReceiver(device: MacFireTVDevice?, code: String) {
        let code = code.filter(\.isNumber)
        guard device?.isRemembered == true || code.count == 6 else {
            report(.failed("Enter the six-digit code shown on the receiver."))
            return
        }
        networkQueue.async { [weak self] in
            guard let self else { return }
            endSession()
            pairingTarget = device?.receiverID
            pairingCode = code
            pairingExpiresAt = .now.advanced(by: .seconds(120))
            acceptingConnections = true
            startListener()
            report(.waitingForReceiver)
        }
    }

    nonisolated func startServer() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            serverRunning = true
            acceptingConnections = true
            startListener()
        }
    }

    /// Listener ownership is independent of a single receiver session.
    nonisolated func startListener() {
        guard serverRunning, listener == nil else { return }
        listenerRetry?.cancel()
        listenerRetry = nil
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let listener = try NWListener(using: parameters)
            listener.service = .init(
                name: Host.current().localizedName ?? "Mac",
                type: "_framesmac._tcp",
                txtRecord: NWTXTRecord(["senderID": Self.senderID])
            )
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    listenerFailures = 0
                    if self.connection == nil { report(.waitingForReceiver) }
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    retryListener("Listener unavailable: \(error.localizedDescription)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, listener === self.listener,
                      serverRunning, acceptingConnections, self.connection == nil else {
                    connection.cancel()
                    return
                }
                if pairingExpiresAt.map({ ContinuousClock.now >= $0 }) == true {
                    pairingCode = ""
                    pairingTarget = nil
                    pairingExpiresAt = nil
                }
                clearHandshakeState()
                receiverID = nil
                rememberedSecret = nil
                usedRememberedSecret = false
                connectedName = "Receiver"
                guard session.begin() != nil else { connection.cancel(); return }
                self.connection = connection
                mediaEncoder.restart()
                report(.connecting(connectedName))
                let generation = session.generation
                let deadline = DispatchWorkItem { [weak self, weak connection] in
                    guard let self, let connection, connection === self.connection,
                          session.generation == generation, currentStreamingKey() == nil else { return }
                    fail("Receiver authentication timed out. Ready for another connection.")
                }
                handshakeDeadline = deadline
                networkQueue.asyncAfter(deadline: .now() + 15, execute: deadline)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection, connection === self.connection else { return }
                    switch state {
                    case .ready: receiveNextChunk(from: connection)
                    case .failed(let error): fail("Connection ended: \(error.localizedDescription)")
                    case .cancelled: endSession(); report(.disconnected)
                    default: break
                    }
                }
                connection.start(queue: networkQueue)
            }
            listener.start(queue: networkQueue)
        } catch {
            retryListener("Could not start listener: \(error.localizedDescription)")
        }
    }

    nonisolated func retryListener(_ message: String) {
        guard serverRunning else { return }
        listenerFailures += 1
        if connection == nil { report(.failed(message)) }
        let retry = DispatchWorkItem { [weak self] in self?.startListener() }
        listenerRetry = retry
        networkQueue.asyncAfter(deadline: .now() + min(15, Double(1 << min(listenerFailures, 4))), execute: retry)
    }

    /// A manual Mac stop blocks automatic reconnection until Resume is chosen.
    /// The listener and advertisement remain alive.
    nonisolated func disconnect() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            acceptingConnections = false
            pairingCode = ""
            pairingTarget = nil
            endSession()
            report(.disconnected)
        }
    }

    nonisolated func endFailedCapture() {
        networkQueue.async { [weak self] in
            self?.fail("Capture stopped producing video. Ready to reconnect.")
        }
    }

    nonisolated func shutdown() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            serverRunning = false
            listenerRetry?.cancel()
            browserRetry?.cancel()
            browser?.cancel()
            browser = nil
            listener?.cancel()
            listener = nil
            endSession()
        }
    }

    nonisolated func forgetSavedConnection(to device: MacFireTVDevice) {
        if let receiverID = device.receiverID {
            TrustedReceiverStore.delete(receiverID)
        }
        disconnect()
    }

    nonisolated static func txtValue(_ key: String, from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let record) = result.metadata,
              case .string(let value) = record.getEntry(for: key),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated static let senderID: String = {
        let key = "discovery.senderID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

}
#endif
