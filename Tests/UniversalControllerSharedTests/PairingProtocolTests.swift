import Foundation
import XCTest
@testable import UniversalControllerShared

final class PairingProtocolTests: XCTestCase {
    func testPairingDescriptorRoundTripsThroughQRPayload() throws {
        let descriptor = PairingDescriptor(
            sessionID: UUID(),
            serviceName: "UniversalController-12345678",
            secret: PairingCrypto.encodeSecret(PairingCrypto.makeSecret()),
            expiresAt: Date().addingTimeInterval(60),
            macName: "Demo Mac"
        )

        let payload = try XCTUnwrap(descriptor.qrPayload)
        let decoded = try PairingDescriptor.parse(qrPayload: payload)

        XCTAssertEqual(decoded.protocolVersion, descriptor.protocolVersion)
        XCTAssertEqual(decoded.sessionID, descriptor.sessionID)
        XCTAssertEqual(decoded.serviceName, descriptor.serviceName)
        XCTAssertEqual(decoded.secret, descriptor.secret)
        XCTAssertEqual(decoded.macName, descriptor.macName)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, descriptor.expiresAt.timeIntervalSince1970, accuracy: 1)
    }

    func testPairingProofValidatesOnlyForMatchingDevice() {
        let secret = PairingCrypto.makeSecret()
        let challenge = PairingCrypto.makeNonce()
        let nonce = PairingCrypto.makeNonce()
        let sessionID = UUID()
        let deviceID = UUID()
        let proof = PairingCrypto.proof(
            secret: secret,
            sessionID: sessionID,
            challenge: challenge,
            clientNonce: nonce,
            deviceID: deviceID
        )

        XCTAssertTrue(PairingCrypto.verify(
            proof: proof,
            secret: secret,
            sessionID: sessionID,
            challenge: challenge,
            clientNonce: nonce,
            deviceID: deviceID
        ))
        XCTAssertFalse(PairingCrypto.verify(
            proof: proof,
            secret: secret,
            sessionID: sessionID,
            challenge: challenge,
            clientNonce: nonce,
            deviceID: UUID()
        ))
    }

    func testWireMessageRoundTrips() throws {
        let message = WireMessage.clientHello(ClientHello(
            protocolVersion: PairingProtocol.version,
            sessionID: UUID(),
            deviceID: UUID(),
            deviceName: "Test iPhone"
        ))

        let data = try WireCodec.encoder.encode(message)
        let decoded = try WireCodec.decoder.decode(WireMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    func testExpiredQRCodeIsRejected() throws {
        let descriptor = PairingDescriptor(
            sessionID: UUID(),
            serviceName: "UniversalController-expired",
            secret: PairingCrypto.encodeSecret(PairingCrypto.makeSecret()),
            expiresAt: Date().addingTimeInterval(-1),
            macName: "Demo Mac"
        )

        let payload = try XCTUnwrap(descriptor.qrPayload)

        XCTAssertThrowsError(try PairingDescriptor.parse(qrPayload: payload)) { error in
            XCTAssertEqual(error as? PairingProtocolError, .expiredQRCode)
        }
    }
}
