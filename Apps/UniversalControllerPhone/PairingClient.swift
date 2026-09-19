import Combine
import Foundation
@preconcurrency import Network
import UIKit

enum PairingClientState: Equatable {
    case disconnected
    case discovering(String)
    case connecting(String)
    case authenticating(String)
    case connected(String)
    case failed(String)
}

@MainActor
final class PairingClient: ObservableObject {
    @Published private(set) var state: PairingClientState = .disconnected
    @Published private(set) var roundTripMilliseconds: Int?
    @Published private(set) var controller: ControllerSnapshot?

    private var descriptor: PairingDescriptor?
    private var browser: NWBrowser?
    private var framedConnection: FramedConnection?
    private var timeoutTask: Task<Void, Never>?
    private var pendingPings: [UUID: Date] = [:]
    private var disconnecting = false

    private let deviceID: UUID = {
        let key = "UniversalControllerDeviceID"
        if let value = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    func connect(using descriptor: PairingDescriptor) {
        disconnect()
        disconnecting = false

        guard !descriptor.isExpired else {
            state = .failed(PairingProtocolError.expiredQRCode.localizedDescription)
            return
        }

        self.descriptor = descriptor
        state = .discovering(descriptor.macName)

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: PairingProtocol.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(browserState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.useMatchingService(from: results)
            }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
        scheduleTimeout()
    }

    func disconnect() {
        disconnecting = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        framedConnection?.cancel()
        framedConnection = nil
        descriptor = nil
        pendingPings.removeAll()
        roundTripMilliseconds = nil
        controller = nil
        state = .disconnected
    }

    func press(_ button: ControllerButton) {
        guard case .connected = state,
              let controller,
              controller.buttons.contains(button) else { return }

        do {
            try framedConnection?.send(.controlEvent(ControlEvent(
                controllerID: controller.controllerID,
                revision: controller.revision,
                controlID: button.id
            )))
        } catch {
            fail(error.localizedDescription)
        }
    }

    func retry() {
        guard let descriptor else {
            state = .disconnected
            return
        }
        connect(using: descriptor)
    }

    private func handleBrowserState(_ browserState: NWBrowser.State) {
        switch browserState {
        case .failed(let error):
            fail("Could not search the local network: \(error.localizedDescription)")
        case .waiting(let error):
            state = .discovering(descriptor?.macName ?? "Mac")
            if case NWError.dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                fail("Allow Local Network access in Settings, then try again.")
            }
        default:
            break
        }
    }

    private func useMatchingService(from results: Set<NWBrowser.Result>) {
        guard let descriptor,
              let result = results.first(where: { result in
                  guard case .service(let name, _, _, _) = result.endpoint else { return false }
                  return name == descriptor.serviceName
              }) else {
            return
        }

        browser?.cancel()
        browser = nil
        state = .connecting(descriptor.macName)

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let framedConnection = FramedConnection(
            connection: NWConnection(to: result.endpoint, using: parameters)
        )
        framedConnection.onMessage = { [weak self] message in
            self?.handle(message)
        }
        framedConnection.onProtocolError = { [weak self] error in
            self?.fail(error.localizedDescription)
        }
        framedConnection.onStateChange = { [weak self] connectionState in
            self?.handleConnectionState(connectionState)
        }
        self.framedConnection = framedConnection
        framedConnection.start()
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            sendHello()
        case .failed(let error):
            fail("Could not connect to the Mac: \(error.localizedDescription)")
        case .cancelled:
            if !disconnecting, case .connected = state {
                fail("The Mac disconnected.")
            }
        default:
            break
        }
    }

    private func sendHello() {
        guard let descriptor else { return }
        state = .authenticating(descriptor.macName)

        do {
            try framedConnection?.send(.clientHello(ClientHello(
                protocolVersion: PairingProtocol.version,
                sessionID: descriptor.sessionID,
                deviceID: deviceID,
                deviceName: UIDevice.current.name
            )))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handle(_ message: WireMessage) {
        switch message {
        case .serverChallenge(let challenge):
            answer(challenge)
        case .paired(let paired):
            guard paired.sessionID == descriptor?.sessionID else {
                fail("The Mac paired with a different session.")
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            state = .connected(paired.macName)
            sendPing()
        case .pong(let pong):
            guard let startedAt = pendingPings.removeValue(forKey: pong.id) else { return }
            roundTripMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        case .schemaSnapshot(let snapshot):
            guard case .connected = state,
                  snapshot.schemaVersion == ControllerSnapshot.currentVersion,
                  snapshot.revision > 0,
                  snapshot.buttons.count <= 32,
                  Set(snapshot.buttons.map(\.id)).count == snapshot.buttons.count else {
                fail("The Mac sent an unsupported controller.")
                return
            }
            controller = snapshot
        case .error(let error):
            fail(error.message)
        case .ping(let ping):
            try? framedConnection?.send(.pong(Pong(id: ping.id, sentAt: ping.sentAt)))
        default:
            fail("The Mac sent an unexpected pairing message.")
        }
    }

    private func answer(_ serverChallenge: ServerChallenge) {
        guard let descriptor,
              serverChallenge.sessionID == descriptor.sessionID,
              let secret = PairingCrypto.decodeSecret(descriptor.secret),
              let challenge = PairingCrypto.decodeSecret(serverChallenge.challenge) else {
            fail("The Mac sent an invalid pairing challenge.")
            return
        }

        let clientNonce = PairingCrypto.makeNonce()
        let proof = PairingCrypto.proof(
            secret: secret,
            sessionID: descriptor.sessionID,
            challenge: challenge,
            clientNonce: clientNonce,
            deviceID: deviceID
        )

        do {
            try framedConnection?.send(.pairingProof(PairingProof(
                sessionID: descriptor.sessionID,
                deviceID: deviceID,
                clientNonce: PairingCrypto.encodeSecret(clientNonce),
                proof: PairingCrypto.encodeSecret(proof)
            )))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func sendPing() {
        let ping = Ping(id: UUID(), sentAt: Date())
        pendingPings[ping.id] = Date()
        do {
            try framedConnection?.send(.ping(ping))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail("Could not find the Mac. Confirm both devices are nearby and try again.")
        }
    }

    private func fail(_ message: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        framedConnection?.cancel()
        framedConnection = nil
        pendingPings.removeAll()
        controller = nil
        state = .failed(message)
    }
}
