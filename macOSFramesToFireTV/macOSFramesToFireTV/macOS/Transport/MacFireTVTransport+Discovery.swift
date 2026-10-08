#if os(macOS)
import Foundation
import Network
import SnapCore

/// Receiver discovery, outgoing/direct connections, and reverse connection setup.
/// This extension uses the same transport state and queues; it creates no new pipeline.
extension MacFireTVTransport {
    func startDiscovery() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            browser?.cancel()
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjour(type: "_iosfiretv._tcp", domain: nil),
                using: parameters
            )
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report(.searching)
                case .failed(let error):
                    self?.report(.failed("Discovery failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
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
                self?.publish(devices)
            }
            browser.start(queue: networkQueue)
        }
    }

    func connect(to device: MacFireTVDevice, code: String) {
        waitForReceiver(device: device, code: code)
    }

    func connectDirect(host: String, code: String) {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else {
            report(.failed("Enter the six-digit code shown on the Fire TV."))
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 49_218)!
        )
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            listener?.cancel()
            listener = nil
            clearSession()
            mediaEncoder.restart()
            pairingCode = normalizedCode
            connectedName = "Fire TV at \(host)"

            let parameters = NWParameters.tcp
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            report(.connecting(connectedName))
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.receiveNextChunk(from: connection)
                case .failed(let error):
                    self.fail("Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.report(.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    /// Advertises a short-lived pairing listener. The Fire TV initiates the
    /// TCP connection, while the existing authenticated media protocol remains
    /// unchanged once the socket is accepted.
    func waitForFireTV(code: String) {
        waitForReceiver(device: nil, code: code)
    }

    func waitForReceiver(device: MacFireTVDevice?, code: String) {
        let normalizedCode = code.filter(\.isNumber)
        let savedSecret = device?.receiverID.flatMap(TrustedReceiverStore.load)
        guard savedSecret != nil || normalizedCode.count == 6 else {
            report(.failed("Enter the six-digit code shown on the Fire TV."))
            return
        }
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            listener?.cancel()
            clearSession()
            mediaEncoder.restart()
            pairingCode = normalizedCode
            connectedName = device?.name ?? "Receiver"
            receiverID = device?.receiverID
            rememberedSecret = savedSecret
            usedRememberedSecret = false

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                if let tcpOptions = parameters.defaultProtocolStack.transportProtocol
                    as? NWProtocolTCP.Options {
                    tcpOptions.noDelay = true
                }
                let listener = try NWListener(using: parameters)
                var serviceTXT = NWTXTRecord([
                    "senderID": Self.senderID,
                ])
                if let receiverID = device?.receiverID {
                    serviceTXT["target"] = receiverID
                }
                listener.service = .init(
                    name: Host.current().localizedName ?? "Mac",
                    type: "_framesmac._tcp",
                    txtRecord: serviceTXT
                )
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, listener === self.listener else { return }
                    switch state {
                    case .ready:
                        self.report(.waitingForReceiver)
                    case .failed(let error):
                        self.fail("Could not accept the Fire TV connection: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    guard self.connection == nil else {
                        connection.cancel()
                        return
                    }
                    self.connection = connection
                    self.report(.connecting(self.connectedName))
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection, connection === self.connection else { return }
                        switch state {
                        case .ready:
                            self.receiveNextChunk(from: connection)
                        case .failed(let error):
                            self.fail("Connection failed: \(error.localizedDescription)")
                        case .cancelled:
                            self.report(.disconnected)
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.networkQueue)
                }
                listener.start(queue: networkQueue)
            } catch {
                fail("Could not start the Mac receiver: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
            mediaEncoder.stop()
            clearSession()
            report(.disconnected)
        }
    }

    func forgetSavedConnection(to device: MacFireTVDevice) {
        if let receiverID = device.receiverID {
            TrustedReceiverStore.delete(receiverID)
        }
        disconnect()
    }

    static func txtValue(_ key: String, from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let record) = result.metadata,
              case .string(let value) = record.getEntry(for: key),
              !value.isEmpty else { return nil }
        return value
    }

    static let senderID: String = {
        let key = "discovery.senderID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

}
#endif
