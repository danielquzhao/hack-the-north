import CryptoKit
import Foundation

enum PairingProtocol {
    static let version = 1
    static let serviceType = "_universalctrl._tcp"
    static let maximumFrameSize = 256 * 1024
    static let sessionLifetime: TimeInterval = 5 * 60
}

struct PairingDescriptor: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sessionID: UUID
    let serviceName: String
    let secret: String
    let expiresAt: Date
    let macName: String

    var isExpired: Bool {
        expiresAt <= Date()
    }

    var qrPayload: String? {
        guard let data = try? WireCodec.encoder.encode(self) else { return nil }
        return "universal-controller://pair/\(data.base64URLEncodedString())"
    }

    init(
        sessionID: UUID,
        serviceName: String,
        secret: String,
        expiresAt: Date,
        macName: String
    ) {
        protocolVersion = PairingProtocol.version
        self.sessionID = sessionID
        self.serviceName = serviceName
        self.secret = secret
        self.expiresAt = expiresAt
        self.macName = macName
    }

    static func parse(qrPayload: String) throws -> PairingDescriptor {
        guard let url = URL(string: qrPayload),
              url.scheme == "universal-controller",
              url.host == "pair",
              let encoded = url.pathComponents.dropFirst().first,
              let data = Data(base64URLEncoded: encoded) else {
            throw PairingProtocolError.invalidQRCode
        }

        let descriptor = try WireCodec.decoder.decode(PairingDescriptor.self, from: data)
        guard descriptor.protocolVersion == PairingProtocol.version else {
            throw PairingProtocolError.unsupportedVersion
        }
        guard !descriptor.isExpired else {
            throw PairingProtocolError.expiredQRCode
        }
        guard PairingCrypto.decodeSecret(descriptor.secret) != nil else {
            throw PairingProtocolError.invalidQRCode
        }
        return descriptor
    }
}

struct ClientHello: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sessionID: UUID
    let deviceID: UUID
    let deviceName: String
}

struct ServerChallenge: Codable, Equatable, Sendable {
    let sessionID: UUID
    let challenge: String
}

struct PairingProof: Codable, Equatable, Sendable {
    let sessionID: UUID
    let deviceID: UUID
    let clientNonce: String
    let proof: String
}

struct Paired: Codable, Equatable, Sendable {
    let sessionID: UUID
    let macName: String
}

struct ControllerButton: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
}

struct ControllerSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let schemaVersion: Int
    let controllerID: UUID
    let revision: Int
    let name: String
    let targetBundleID: String
    let buttons: [ControllerButton]

    func accepts(_ event: ControlEvent) -> Bool {
        schemaVersion == Self.currentVersion &&
        controllerID == event.controllerID &&
        revision == event.revision &&
        buttons.contains { $0.id == event.controlID }
    }
}

struct ControlEvent: Codable, Equatable, Sendable {
    let controllerID: UUID
    let revision: Int
    let controlID: String
}

struct Ping: Codable, Equatable, Sendable {
    let id: UUID
    let sentAt: Date
}

struct Pong: Codable, Equatable, Sendable {
    let id: UUID
    let sentAt: Date
}

struct ProtocolErrorMessage: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

enum WireMessage: Equatable, Sendable {
    case clientHello(ClientHello)
    case serverChallenge(ServerChallenge)
    case pairingProof(PairingProof)
    case paired(Paired)
    case schemaSnapshot(ControllerSnapshot)
    case controlEvent(ControlEvent)
    case ping(Ping)
    case pong(Pong)
    case error(ProtocolErrorMessage)
}

extension WireMessage: Codable {
    private enum Kind: String, Codable {
        case clientHello
        case serverChallenge
        case pairingProof
        case paired
        case schemaSnapshot
        case controlEvent
        case ping
        case pong
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .clientHello:
            self = .clientHello(try container.decode(ClientHello.self, forKey: .payload))
        case .serverChallenge:
            self = .serverChallenge(try container.decode(ServerChallenge.self, forKey: .payload))
        case .pairingProof:
            self = .pairingProof(try container.decode(PairingProof.self, forKey: .payload))
        case .paired:
            self = .paired(try container.decode(Paired.self, forKey: .payload))
        case .schemaSnapshot:
            self = .schemaSnapshot(try container.decode(ControllerSnapshot.self, forKey: .payload))
        case .controlEvent:
            self = .controlEvent(try container.decode(ControlEvent.self, forKey: .payload))
        case .ping:
            self = .ping(try container.decode(Ping.self, forKey: .payload))
        case .pong:
            self = .pong(try container.decode(Pong.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ProtocolErrorMessage.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clientHello(let payload):
            try container.encode(Kind.clientHello, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .serverChallenge(let payload):
            try container.encode(Kind.serverChallenge, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .pairingProof(let payload):
            try container.encode(Kind.pairingProof, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .paired(let payload):
            try container.encode(Kind.paired, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .schemaSnapshot(let payload):
            try container.encode(Kind.schemaSnapshot, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .controlEvent(let payload):
            try container.encode(Kind.controlEvent, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .ping(let payload):
            try container.encode(Kind.ping, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .pong(let payload):
            try container.encode(Kind.pong, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .error(let payload):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

enum WireCodec {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum PairingCrypto {
    static func makeSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func makeNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func encodeSecret(_ secret: Data) -> String {
        secret.base64URLEncodedString()
    }

    static func decodeSecret(_ encoded: String) -> Data? {
        Data(base64URLEncoded: encoded)
    }

    static func proof(
        secret: Data,
        sessionID: UUID,
        challenge: Data,
        clientNonce: Data,
        deviceID: UUID
    ) -> Data {
        let key = SymmetricKey(data: secret)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: proofPayload(
                sessionID: sessionID,
                challenge: challenge,
                clientNonce: clientNonce,
                deviceID: deviceID
            ),
            using: key
        )
        return Data(authenticationCode)
    }

    static func verify(
        proof: Data,
        secret: Data,
        sessionID: UUID,
        challenge: Data,
        clientNonce: Data,
        deviceID: UUID
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: proofPayload(
                sessionID: sessionID,
                challenge: challenge,
                clientNonce: clientNonce,
                deviceID: deviceID
            ),
            using: SymmetricKey(data: secret)
        )
    }

    private static func proofPayload(
        sessionID: UUID,
        challenge: Data,
        clientNonce: Data,
        deviceID: UUID
    ) -> Data {
        var data = Data("universal-controller-pairing-v1".utf8)
        data.append(Data(sessionID.uuidString.utf8))
        data.append(challenge)
        data.append(clientNonce)
        data.append(Data(deviceID.uuidString.utf8))
        return data
    }
}

enum PairingProtocolError: LocalizedError, Equatable {
    case invalidQRCode
    case unsupportedVersion
    case expiredQRCode
    case invalidFrame
    case frameTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidQRCode:
            "This is not a valid Universal Controller QR code."
        case .unsupportedVersion:
            "This QR code uses an unsupported protocol version."
        case .expiredQRCode:
            "This pairing QR code has expired. Create a new one on the Mac."
        case .invalidFrame:
            "The paired device sent an invalid message."
        case .frameTooLarge:
            "The paired device sent a message that was too large."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
