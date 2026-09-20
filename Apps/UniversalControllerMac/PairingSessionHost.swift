import Combine
import Foundation
@preconcurrency import Network

struct PairedPeerInfo: Equatable, Identifiable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let seatIndex: Int

    var id: UUID { deviceID }

    var seatLabel: String {
        "Seat \(seatIndex + 1)"
    }
}

enum PairingHostState: Equatable {
    case idle
    case starting
    /// QR is visible; zero or more seats may already be filled.
    case advertising
    case authenticating(String)
    /// Every seat has a phone; advertising has stopped.
    case full
    case failed(String)

    var isSessionActive: Bool {
        switch self {
        case .starting, .advertising, .authenticating, .full:
            true
        case .idle, .failed:
            false
        }
    }
}

@MainActor
final class PairingSessionHost: ObservableObject {
    @Published private(set) var state: PairingHostState = .idle
    @Published private(set) var descriptor: PairingDescriptor?
    @Published private(set) var lastPingAt: Date?
    @Published private(set) var peers: [PairedPeerInfo] = []
    @Published private(set) var sessionPack: ControllerSessionPack?

    /// Fired with the seat that owns the event and the event payload.
    var onControlEvent: ((Int, ControlEvent) -> Void)?
    var onConnectionEnded: (() -> Void)?

    private struct PeerConnection {
        let info: PairedPeerInfo
        let connection: FramedConnection
        var lastSequenceByControlID: [String: UInt64] = [:]
    }

    private struct PendingHandshake {
        let connection: FramedConnection
        var challenge: Data?
        var deviceID: UUID?
        var deviceName: String?
    }

    private var listener: NWListener?
    private var secret: Data?
    private var pending: PendingHandshake?
    private var connectedPeers: [UUID: PeerConnection] = [:]
    private var expirationTask: Task<Void, Never>?

    var seatCount: Int {
        sessionPack?.seatCount ?? 0
    }

    var filledSeatCount: Int {
        peers.count
    }

    var openSeatCount: Int {
        max(0, seatCount - filledSeatCount)
    }

    var isAcceptingMorePeers: Bool {
        openSeatCount > 0 && listener != nil && descriptor?.isExpired == false
    }

    func startSession(pack: ControllerSessionPack) {
        stopSession()

        do {
            try SchemaValidator.validate(pack)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        sessionPack = pack
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

    /// Backward-compatible single-controller start.
    func startSession(controller: ControllerDocument) {
        startSession(pack: .single(controller))
    }

    func publishPack(_ pack: ControllerSessionPack) throws {
        try SchemaValidator.validate(pack)
        sessionPack = pack
        for peer in connectedPeers.values {
            guard let document = pack.controller(at: peer.info.seatIndex) else { continue }
            try peer.connection.send(.schemaSnapshot(document))
        }
        refreshPublishedState()
    }

    func publishController(_ document: ControllerDocument) throws {
        guard var pack = sessionPack else {
            try SchemaValidator.validate(document)
            // Legacy single-seat publish when no pack is loaded.
            for peer in connectedPeers.values {
                try peer.connection.send(.schemaSnapshot(document))
            }
            return
        }
        pack.updateSharedChrome(
            name: document.name,
            preferredOrientation: document.preferredOrientation,
            layouts: document.layouts,
            controls: document.controls,
            revision: document.revision
        )
        // Keep the edited seat's bindings from `document` when it matches a seat id.
        if let seat = pack.seats.first(where: { $0.controller.id == document.id }) {
            pack.updateBindings(document.bindings, at: seat.index)
        }
        try publishPack(pack)
    }

    func stopSession(notifyPeer: Bool = true) {
        let hadPeers = !connectedPeers.isEmpty
        if hadPeers {
            onConnectionEnded?()
        }
        onConnectionEnded = nil
        expirationTask?.cancel()
        expirationTask = nil
        listener?.cancel()
        listener = nil
        if notifyPeer {
            for peer in connectedPeers.values {
                peer.connection.closeGracefully()
            }
        } else {
            for peer in connectedPeers.values {
                peer.connection.cancel()
            }
        }
        pending?.connection.cancel()
        pending = nil
        connectedPeers.removeAll()
        peers = []
        descriptor = nil
        secret = nil
        lastPingAt = nil
        sessionPack = nil
        onControlEvent = nil
        state = .idle
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            refreshPublishedState()
        case .failed(let error):
            state = .failed("Could not advertise this Mac: \(error.localizedDescription)")
        case .cancelled:
            break
        case .setup, .waiting:
            if connectedPeers.isEmpty {
                state = .starting
            }
        @unknown default:
            state = .failed("The Mac entered an unknown network state.")
        }
    }

    private func accept(_ connection: NWConnection) {
        guard pending == nil,
              isAcceptingMorePeers,
              nextAvailableSeatIndex() != nil else {
            connection.cancel()
            return
        }

        let framedConnection = FramedConnection(connection: connection)
        framedConnection.onMessage = { [weak self] message in
            self?.handle(message, from: framedConnection)
        }
        framedConnection.onProtocolError = { [weak self] error in
            self?.failHandshakeOrPeer(
                connection: framedConnection,
                message: error.localizedDescription
            )
        }
        framedConnection.onConnectionClosed = { [weak self] in
            self?.failHandshakeOrPeer(
                connection: framedConnection,
                message: "An iPhone disconnected."
            )
        }
        framedConnection.onStateChange = { [weak self] connectionState in
            self?.handleConnectionState(connectionState, connection: framedConnection)
        }
        pending = PendingHandshake(connection: framedConnection)
        framedConnection.start()
    }

    private func handleConnectionState(
        _ connectionState: NWConnection.State,
        connection: FramedConnection
    ) {
        switch connectionState {
        case .failed(let error):
            failHandshakeOrPeer(connection: connection, message: error.localizedDescription)
        case .cancelled:
            failHandshakeOrPeer(connection: connection, message: "An iPhone disconnected.")
        default:
            break
        }
    }

    private func handle(_ message: WireMessage, from connection: FramedConnection) {
        if let peerID = connectedPeers.first(where: { $0.value.connection === connection })?.key {
            handlePairedMessage(message, peerID: peerID)
            return
        }
        guard pending?.connection === connection else {
            connection.cancel()
            return
        }
        handleHandshakeMessage(message)
    }

    private func handleHandshakeMessage(_ message: WireMessage) {
        switch message {
        case .clientHello(let hello):
            handle(hello)
        case .pairingProof(let proof):
            handle(proof)
        default:
            rejectPending(code: "unexpected_message", message: "Unexpected pairing message.")
        }
    }

    private func handlePairedMessage(_ message: WireMessage, peerID: UUID) {
        guard var peer = connectedPeers[peerID] else { return }
        switch message {
        case .ping(let ping):
            lastPingAt = Date()
            try? peer.connection.send(.pong(Pong(id: ping.id, sentAt: ping.sentAt)))
        case .controlEvent(let event):
            guard let pack = sessionPack,
                  let controller = pack.controller(at: peer.info.seatIndex) else {
                rejectPeer(
                    peerID,
                    code: "invalid_control_event",
                    message: "No controller is active for this seat."
                )
                return
            }
            do {
                _ = try SchemaValidator.binding(for: event, in: controller)
                let previousSequence = peer.lastSequenceByControlID[event.controlID] ?? 0
                guard event.sequence > previousSequence else { return }
                peer.lastSequenceByControlID[event.controlID] = event.sequence
                connectedPeers[peerID] = peer
                onControlEvent?(peer.info.seatIndex, event)
            } catch {
                rejectPeer(peerID, code: "invalid_control_event", message: error.localizedDescription)
            }
        case .disconnect:
            removePeer(peerID, notifyPeer: false, endSessionIfEmpty: true)
        default:
            rejectPeer(peerID, code: "unexpected_message", message: "Unexpected pairing message.")
        }
    }

    private func handle(_ hello: ClientHello) {
        guard let descriptor, !descriptor.isExpired else {
            rejectPending(code: "expired", message: "The pairing session has expired.")
            return
        }
        guard hello.protocolVersion == PairingProtocol.version else {
            rejectPending(code: "unsupported_version", message: "The phone uses an unsupported protocol version.")
            return
        }
        guard hello.sessionID == descriptor.sessionID else {
            rejectPending(code: "wrong_session", message: "This QR code belongs to another session.")
            return
        }
        guard connectedPeers[hello.deviceID] == nil else {
            rejectPending(code: "already_paired", message: "This iPhone is already connected.")
            return
        }
        guard nextAvailableSeatIndex() != nil else {
            rejectPending(code: "session_full", message: "All player seats are already filled.")
            return
        }

        let challenge = PairingCrypto.makeNonce()
        pending?.challenge = challenge
        pending?.deviceID = hello.deviceID
        pending?.deviceName = hello.deviceName
        state = .authenticating(hello.deviceName)

        do {
            try pending?.connection.send(.serverChallenge(ServerChallenge(
                sessionID: descriptor.sessionID,
                challenge: PairingCrypto.encodeSecret(challenge)
            )))
        } catch {
            failHandshakeOrPeer(connection: pending?.connection, message: error.localizedDescription)
        }
    }

    private func handle(_ proof: PairingProof) {
        guard let descriptor,
              let secret,
              let pending,
              let challenge = pending.challenge,
              let pendingDeviceID = pending.deviceID,
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
              ),
              let seatIndex = nextAvailableSeatIndex(),
              let pack = sessionPack,
              let controller = pack.controller(at: seatIndex) else {
            rejectPending(code: "invalid_proof", message: "The pairing proof was not valid.")
            return
        }

        let deviceName = pending.deviceName ?? "iPhone"
        let info = PairedPeerInfo(
            deviceID: pendingDeviceID,
            deviceName: deviceName,
            seatIndex: seatIndex
        )

        do {
            try pending.connection.send(.paired(Paired(
                sessionID: descriptor.sessionID,
                macName: descriptor.macName
            )))
            try pending.connection.send(.schemaSnapshot(controller))
            connectedPeers[pendingDeviceID] = PeerConnection(info: info, connection: pending.connection)
            self.pending = nil
            publishPeers()
            if openSeatCount == 0 {
                stopAdvertising(keepPeers: true)
                state = .full
            } else {
                state = .advertising
            }
        } catch {
            failHandshakeOrPeer(connection: pending.connection, message: error.localizedDescription)
        }
    }

    private func nextAvailableSeatIndex() -> Int? {
        guard let pack = sessionPack else { return nil }
        let occupied = Set(connectedPeers.values.map(\.info.seatIndex))
        return (0..<pack.seatCount).first { !occupied.contains($0) }
    }

    private func rejectPending(code: String, message: String) {
        try? pending?.connection.send(.error(ProtocolErrorMessage(code: code, message: message)))
        pending?.connection.cancel()
        pending = nil
        refreshPublishedState()
    }

    private func rejectPeer(_ peerID: UUID, code: String, message: String) {
        if let peer = connectedPeers[peerID] {
            try? peer.connection.send(.error(ProtocolErrorMessage(code: code, message: message)))
            peer.connection.cancel()
        }
        removePeer(peerID, notifyPeer: false, endSessionIfEmpty: true)
    }

    private func failHandshakeOrPeer(connection: FramedConnection?, message: String) {
        guard let connection else { return }
        if pending?.connection === connection {
            pending?.connection.cancel()
            pending = nil
            refreshPublishedState()
            return
        }
        if let peerID = connectedPeers.first(where: { $0.value.connection === connection })?.key {
            removePeer(peerID, notifyPeer: false, endSessionIfEmpty: true, failureMessage: message)
        }
    }

    private func removePeer(
        _ peerID: UUID,
        notifyPeer: Bool,
        endSessionIfEmpty: Bool,
        failureMessage: String? = nil
    ) {
        guard let peer = connectedPeers.removeValue(forKey: peerID) else { return }
        if notifyPeer {
            peer.connection.closeGracefully()
        } else {
            peer.connection.cancel()
        }
        publishPeers()

        if connectedPeers.isEmpty {
            onConnectionEnded?()
            onConnectionEnded = nil
            onControlEvent = nil
            if endSessionIfEmpty {
                if let failureMessage, listener == nil || descriptor?.isExpired == true {
                    stopAdvertising(keepPeers: false)
                    state = .failed(failureMessage)
                } else if listener != nil, descriptor?.isExpired == false {
                    state = .advertising
                } else {
                    state = .failed(failureMessage ?? "All iPhones disconnected.")
                }
            }
        } else if isAcceptingMorePeers {
            state = .advertising
        } else if openSeatCount == 0 {
            state = .full
        } else {
            // A seat freed up after we had stopped advertising — reopen if QR still valid.
            refreshPublishedState()
        }
    }

    private func stopAdvertising(keepPeers: Bool) {
        expirationTask?.cancel()
        expirationTask = nil
        listener?.cancel()
        listener = nil
        if !keepPeers {
            descriptor = nil
            secret = nil
        }
    }

    private func publishPeers() {
        peers = connectedPeers.values.map(\.info).sorted { $0.seatIndex < $1.seatIndex }
    }

    private func refreshPublishedState() {
        if connectedPeers.isEmpty == false, openSeatCount == 0 {
            stopAdvertising(keepPeers: true)
            state = .full
            return
        }
        if listener != nil, descriptor?.isExpired == false {
            if case .authenticating = state, pending != nil {
                return
            }
            state = .advertising
        }
    }

    private func scheduleExpiration(for date: Date) {
        expirationTask = Task { [weak self] in
            let duration = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.expireAdvertising()
        }
    }

    private func expireAdvertising() {
        pending?.connection.cancel()
        pending = nil
        listener?.cancel()
        listener = nil
        descriptor = nil
        secret = nil
        if connectedPeers.isEmpty {
            onConnectionEnded?()
            onConnectionEnded = nil
            onControlEvent = nil
            state = .failed("The pairing QR code expired. Create a new one.")
        } else {
            // Keep connected phones; additional seats require a new pairing session.
            state = .full
        }
    }
}
