import Combine
import Foundation
@preconcurrency import Network

enum PairingHostState: Equatable {
    case idle
    case starting
    case waiting
    case authenticating(String)
    case connected(String)
    case failed(String)
}

@MainActor
final class PairingSessionHost: ObservableObject {
    @Published private(set) var state: PairingHostState = .idle
    @Published private(set) var descriptor: PairingDescriptor?
    @Published private(set) var lastPingAt: Date?
    @Published private(set) var controller: ControllerDocument?

    var onControlEvent: ((ControlEvent) -> Void)?
    var onConnectionEnded: (() -> Void)?

    private var listener: NWListener?
    private var framedConnection: FramedConnection?
    private var secret: Data?
    private var challenge: Data?
    private var pendingDeviceID: UUID?
    private var pendingDeviceName: String?
    private var expirationTask: Task<Void, Never>?
    private var lastSequenceByControlID: [String: UInt64] = [:]

    func startSession(controller: ControllerDocument? = nil) {
        stopSession()

        if let controller {
            do {
                try SchemaValidator.validate(controller)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        self.controller = controller
        state = .starting

        do {
            let sessionID = UUID()
            let secret = PairingCrypto.makeSecret()
            let serviceName = "UniversalController-\(sessionID.uuidString.prefix(8))"
            let descriptor = PairingDescriptor(
                sessionID: sessionID,
                serviceName: serviceName,
                secret: PairingCrypto.encodeSecret(secret),
                expiresAt: Date().addingTimeInterval(PairingProtocol.sessionLifetime),
                macName: Host.current().localizedName ?? "Mac"
            )

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            let txtRecord = NetService.data(fromTXTRecord: [
                "v": Data(String(PairingProtocol.version).utf8),
                "sid": Data(sessionID.uuidString.utf8),
            ])
            listener.service = NWListener.Service(
                name: serviceName,
                type: PairingProtocol.serviceType,
                domain: nil,
                txtRecord: txtRecord
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }

            self.secret = secret
            self.descriptor = descriptor
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
            scheduleExpiration(for: descriptor.expiresAt)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func publishController(_ document: ControllerDocument) throws {
        try SchemaValidator.validate(document)
        controller = document
        guard case .connected = state else { return }
        try framedConnection?.send(.schemaSnapshot(document))
    }

    func stopSession(notifyPeer: Bool = true) {
        onConnectionEnded?()
        onConnectionEnded = nil
        let wasConnected: Bool
        if case .connected = state {
            wasConnected = true
        } else {
            wasConnected = false
        }
        expirationTask?.cancel()
        expirationTask = nil
        listener?.cancel()
        listener = nil
        if wasConnected && notifyPeer {
            framedConnection?.closeGracefully()
        } else {
            framedConnection?.cancel()
        }
        framedConnection = nil
        descriptor = nil
        secret = nil
        challenge = nil
        pendingDeviceID = nil
        pendingDeviceName = nil
        lastPingAt = nil
        controller = nil
        onControlEvent = nil
        lastSequenceByControlID.removeAll()
        state = .idle
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state = .waiting
        case .failed(let error):
            state = .failed("Could not advertise this Mac: \(error.localizedDescription)")
        case .cancelled:
            break
        case .setup, .waiting:
            state = .starting
        @unknown default:
            state = .failed("The Mac entered an unknown network state.")
        }
    }

    private func accept(_ connection: NWConnection) {
        guard framedConnection == nil, descriptor?.isExpired == false else {
            connection.cancel()
            return
        }

        let framedConnection = FramedConnection(connection: connection)
        framedConnection.onMessage = { [weak self] message in
            self?.handle(message)
        }
        framedConnection.onProtocolError = { [weak self] error in
            self?.connectionFailed(error.localizedDescription)
        }
        framedConnection.onConnectionClosed = { [weak self] in
            self?.connectionFailed("The iPhone disconnected.")
        }
        framedConnection.onStateChange = { [weak self] connectionState in
            self?.handleConnectionState(connectionState)
        }
        self.framedConnection = framedConnection
        framedConnection.start()
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .failed(let error):
            connectionFailed(error.localizedDescription)
        case .cancelled:
            connectionFailed("The iPhone disconnected.")
        default:
            break
        }
    }

    private func handle(_ message: WireMessage) {
        switch message {
        case .clientHello(let hello):
            handle(hello)
        case .pairingProof(let proof):
            handle(proof)
        case .ping(let ping):
            lastPingAt = Date()
            try? framedConnection?.send(.pong(Pong(id: ping.id, sentAt: ping.sentAt)))
        case .controlEvent(let event):
            guard case .connected = state, let controller else {
                rejectConnection(code: "invalid_control_event", message: "No controller is active.")
                return
            }
            do {
                _ = try SchemaValidator.binding(for: event, in: controller)
                let previousSequence = lastSequenceByControlID[event.controlID] ?? 0
                guard event.sequence > previousSequence else { return }
                lastSequenceByControlID[event.controlID] = event.sequence
                onControlEvent?(event)
            } catch {
                rejectConnection(code: "invalid_control_event", message: error.localizedDescription)
            }
        case .disconnect:
            stopSession(notifyPeer: false)
        default:
            rejectConnection(code: "unexpected_message", message: "Unexpected pairing message.")
        }
    }

    private func handle(_ hello: ClientHello) {
        guard let descriptor, !descriptor.isExpired else {
            rejectConnection(code: "expired", message: "The pairing session has expired.")
            return
        }
        guard hello.protocolVersion == PairingProtocol.version else {
            rejectConnection(code: "unsupported_version", message: "The phone uses an unsupported protocol version.")
            return
        }
        guard hello.sessionID == descriptor.sessionID else {
            rejectConnection(code: "wrong_session", message: "This QR code belongs to another session.")
            return
        }

        let challenge = PairingCrypto.makeNonce()
        self.challenge = challenge
        pendingDeviceID = hello.deviceID
        pendingDeviceName = hello.deviceName
        state = .authenticating(hello.deviceName)

        do {
            try framedConnection?.send(.serverChallenge(ServerChallenge(
                sessionID: descriptor.sessionID,
                challenge: PairingCrypto.encodeSecret(challenge)
            )))
        } catch {
            connectionFailed(error.localizedDescription)
        }
    }

    private func handle(_ proof: PairingProof) {
        guard let descriptor,
              let secret,
              let challenge,
              let pendingDeviceID,
              proof.sessionID == descriptor.sessionID,
              proof.deviceID == pendingDeviceID,
              let clientNonce = PairingCrypto.decodeSecret(proof.clientNonce),
              let proofData = PairingCrypto.decodeSecret(proof.proof),
              PairingCrypto.verify(
                proof: proofData,
                secret: secret,
                sessionID: descriptor.sessionID,
                challenge: challenge,
                clientNonce: clientNonce,
                deviceID: pendingDeviceID
              ) else {
            rejectConnection(code: "invalid_proof", message: "The pairing proof was not valid.")
            return
        }

        let deviceName = pendingDeviceName ?? "iPhone"
        do {
            try framedConnection?.send(.paired(Paired(
                sessionID: descriptor.sessionID,
                macName: descriptor.macName
            )))
            if let controller {
                try framedConnection?.send(.schemaSnapshot(controller))
            }
            state = .connected(deviceName)
            listener?.cancel()
            listener = nil
            expirationTask?.cancel()
            expirationTask = nil
            self.challenge = nil
            self.pendingDeviceID = nil
            self.pendingDeviceName = nil
        } catch {
            connectionFailed(error.localizedDescription)
        }
    }

    private func rejectConnection(code: String, message: String) {
        if case .connected = state {
            onConnectionEnded?()
            onConnectionEnded = nil
            onControlEvent = nil
        }
        try? framedConnection?.send(.error(ProtocolErrorMessage(code: code, message: message)))
        framedConnection?.cancel()
        framedConnection = nil
        challenge = nil
        pendingDeviceID = nil
        pendingDeviceName = nil
        state = listener != nil && descriptor?.isExpired == false ? .waiting : .failed(message)
    }

    private func connectionFailed(_ message: String) {
        if case .connected = state {
            onConnectionEnded?()
            onConnectionEnded = nil
            onControlEvent = nil
        }
        framedConnection?.cancel()
        framedConnection = nil
        challenge = nil
        pendingDeviceID = nil
        pendingDeviceName = nil

        if listener != nil, descriptor?.isExpired == false {
            state = .waiting
        } else {
            state = .failed(message)
        }
    }

    private func scheduleExpiration(for date: Date) {
        expirationTask = Task { [weak self] in
            let duration = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.expireSession()
        }
    }

    private func expireSession() {
        onConnectionEnded?()
        onConnectionEnded = nil
        onControlEvent = nil
        listener?.cancel()
        listener = nil
        framedConnection?.cancel()
        framedConnection = nil
        state = .failed("The pairing QR code expired. Create a new one.")
    }
}
