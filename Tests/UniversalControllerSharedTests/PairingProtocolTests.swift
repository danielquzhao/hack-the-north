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
        let hello = WireMessage.clientHello(ClientHello(
            protocolVersion: PairingProtocol.version,
            sessionID: UUID(),
            deviceID: UUID(),
            deviceName: "Test iPhone"
        ))

        for message in [hello, .disconnect] {
            let data = try WireCodec.encoder.encode(message)
            let decoded = try WireCodec.decoder.decode(WireMessage.self, from: data)
            XCTAssertEqual(decoded, message)
        }
    }

    func testControllerDocumentAndEventRoundTrip() throws {
        let document = ControllerDocument(
            schemaVersion: ControllerDocument.currentSchemaVersion,
            id: UUID(),
            revision: 1,
            name: "Keynote Presenter",
            target: ControllerTarget(
                bundleIdentifier: "com.apple.iWork.Keynote",
                displayName: "Keynote"
            ),
            preferredOrientation: .portrait,
            layouts: ControllerLayouts(
                portrait: AbsoluteLayoutBuilder.fromGrid(
                    columns: 1,
                    specs: [("next-slide", 1, 1)]
                ),
                landscape: AbsoluteLayoutBuilder.fromGrid(
                    columns: 2,
                    specs: [("next-slide", 2, 1)]
                )
            ),
            controls: [.button(id: "next-slide", label: "Next Slide")],
            bindings: [ControlBinding(
                id: "next-slide-binding",
                controlID: "next-slide",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .rightArrow, modifiers: []))
            )]
        )
        let event = ControlEvent(
            controllerID: document.id,
            revision: document.revision,
            controlID: "next-slide",
            event: .triggered,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            value: .none
        )

        for message in [WireMessage.schemaSnapshot(document), .controlEvent(event)] {
            let encoded = try WireCodec.encoder.encode(message)
            XCTAssertEqual(try WireCodec.decoder.decode(WireMessage.self, from: encoded), message)
        }
        XCTAssertNoThrow(try SchemaValidator.validate(document))
        XCTAssertEqual(
            try SchemaValidator.binding(for: event, in: document),
            document.bindings[0]
        )
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
