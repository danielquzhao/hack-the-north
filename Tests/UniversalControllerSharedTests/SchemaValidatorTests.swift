import Foundation
import XCTest
@testable import UniversalControllerShared

final class SchemaValidatorTests: XCTestCase {
    func testCapabilityCatalogExposesOnlyImplementedCapabilities() {
        XCTAssertEqual(
            ControllerCapabilityCatalog.current.controls,
            [ControlCapabilityDescriptor(
                id: .button,
                outputKind: .none,
                events: [.triggered]
            ), ControlCapabilityDescriptor(
                id: .joystick,
                outputKind: .vector2,
                events: [.changed]
            ), ControlCapabilityDescriptor(
                id: .motion,
                outputKind: .vector2,
                events: [.changed]
            )]
        )
        XCTAssertEqual(
            ControllerCapabilityCatalog.current.actions,
            [ActionCapabilityDescriptor(
                id: .keyChord,
                acceptedInputKinds: [.none]
            ), ActionCapabilityDescriptor(
                id: .mouseMove,
                acceptedInputKinds: [.vector2]
            )]
        )
        XCTAssertEqual(ControllerCapabilityCatalog.current.buttonFaces, ButtonFace.allCases)
        XCTAssertEqual(ControllerCapabilityCatalog.current.motionSources, [.tilt])
    }

    func testValidButtonControllerPassesValidation() {
        XCTAssertNoThrow(try SchemaValidator.validate(makeDocument()))
    }

    func testDuplicateControlIDsAreRejected() {
        let document = makeDocument(
            controls: [
                .button(id: "next", label: "Next"),
                .button(id: "next", label: "Duplicate"),
            ],
            items: [
                ControllerLayoutItem(controlID: "next", columnSpan: 1, rowSpan: 1),
            ]
        )

        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testLayoutMustReferenceEveryControl() {
        let document = makeDocument(items: [])

        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testStaleControlEventIsRejected() throws {
        let document = makeDocument()
        let event = ControlEvent(
            controllerID: document.id,
            revision: document.revision + 1,
            controlID: "next",
            event: .triggered,
            sequence: 1,
            timestamp: Date(),
            value: .none
        )

        XCTAssertThrowsError(try SchemaValidator.binding(for: event, in: document))
    }

    func testControlEventValueMustMatchCapabilityOutput() {
        let document = makeDocument()
        let event = ControlEvent(
            controllerID: document.id,
            revision: document.revision,
            controlID: "next",
            event: .triggered,
            sequence: 1,
            timestamp: Date(),
            value: .scalar(0.5)
        )

        XCTAssertThrowsError(try SchemaValidator.binding(for: event, in: document))
    }

    func testGamepadControlsAndMotionBindingValidate() throws {
        let document = makeDocument(
            controls: [
                .button(id: "a", label: "Next", face: .a),
                .joystick(id: "stick", label: "Pointer"),
                .tilt(id: "tilt", label: "Tilt Pointer"),
            ],
            items: [
                ControllerLayoutItem(controlID: "a", columnSpan: 1, rowSpan: 1),
                ControllerLayoutItem(controlID: "stick", columnSpan: 1, rowSpan: 2),
                ControllerLayoutItem(controlID: "tilt", columnSpan: 1, rowSpan: 1),
            ],
            bindings: [
                ControlBinding(id: "a-press", controlID: "a", event: .triggered,
                               action: .keyChord(KeyChordAction(key: .rightArrow, modifiers: []))),
                ControlBinding(id: "stick-move", controlID: "stick", event: .changed,
                               action: .mouseMove(MouseMoveAction(gain: 14, deadZone: 0.1))),
                ControlBinding(id: "tilt-move", controlID: "tilt", event: .changed,
                               action: .mouseMove(MouseMoveAction(gain: 9, deadZone: 0.18))),
            ]
        )
        try SchemaValidator.validate(document)
        let wireData = try WireCodec.encoder.encode(WireMessage.schemaSnapshot(document))
        XCTAssertEqual(
            try WireCodec.decoder.decode(WireMessage.self, from: wireData),
            .schemaSnapshot(document)
        )

        let motionEvent = ControlEvent(
            controllerID: document.id,
            revision: document.revision,
            controlID: "tilt",
            event: .changed,
            sequence: 1,
            timestamp: Date(),
            value: .vector2(Vector2Value(x: 0.4, y: -0.2))
        )
        XCTAssertEqual(try SchemaValidator.binding(for: motionEvent, in: document).id, "tilt-move")

        let invalidEvent = ControlEvent(
            controllerID: document.id,
            revision: document.revision,
            controlID: "tilt",
            event: .changed,
            sequence: 2,
            timestamp: Date(),
            value: .vector2(Vector2Value(x: 2, y: 0))
        )
        XCTAssertThrowsError(try SchemaValidator.binding(for: invalidEvent, in: document))
    }

    func testInvalidPointerGainIsRejected() {
        let document = makeDocument(
            controls: [.joystick(id: "stick", label: "Pointer")],
            items: [ControllerLayoutItem(controlID: "stick", columnSpan: 1, rowSpan: 1)],
            bindings: [ControlBinding(
                id: "stick-move",
                controlID: "stick",
                event: .changed,
                action: .mouseMove(MouseMoveAction(gain: 1_000, deadZone: 0.1))
            )]
        )
        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testUnboundControlIsRejected() {
        let document = makeDocument(
            controls: [.button(id: "next", label: "Next"), .button(id: "other", label: "Other")],
            items: [
                ControllerLayoutItem(controlID: "next", columnSpan: 1, rowSpan: 1),
                ControllerLayoutItem(controlID: "other", columnSpan: 1, rowSpan: 1),
            ]
        )
        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    private func makeDocument(
        controls: [ControlDefinition] = [.button(id: "next", label: "Next")],
        items: [ControllerLayoutItem] = [
            ControllerLayoutItem(controlID: "next", columnSpan: 1, rowSpan: 1),
        ],
        bindings: [ControlBinding]? = nil
    ) -> ControllerDocument {
        ControllerDocument(
            schemaVersion: ControllerDocument.currentSchemaVersion,
            id: UUID(),
            revision: 1,
            name: "Test Controller",
            target: ControllerTarget(
                bundleIdentifier: "com.example.target",
                displayName: "Target"
            ),
            layout: ControllerLayout(columns: 1, items: items),
            controls: controls,
            bindings: bindings ?? [ControlBinding(
                id: "next-binding",
                controlID: "next",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .rightArrow, modifiers: []))
            )]
        )
    }
}
