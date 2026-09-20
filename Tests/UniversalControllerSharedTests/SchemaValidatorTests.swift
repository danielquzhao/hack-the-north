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
                events: [.triggered, .began, .ended],
                displayName: "Button",
                systemImage: "hand.tap.fill",
                summary: "Tap to send a keyboard shortcut",
                defaultWidth: 0.28,
                defaultHeight: 0.18,
                occupiesLayout: true
            ), ControlCapabilityDescriptor(
                id: .joystick,
                outputKind: .vector2,
                events: [.changed],
                displayName: "Joystick",
                systemImage: "circle.circle",
                summary: "Stick that moves the Mac pointer",
                defaultWidth: 0.36,
                defaultHeight: 0.36,
                occupiesLayout: true
            ), ControlCapabilityDescriptor(
                id: .motion,
                outputKind: .vector2,
                events: [.changed],
                displayName: "Tilt",
                systemImage: "gyroscope",
                summary: "Phone tilt moves the Mac pointer",
                defaultWidth: 0.16,
                defaultHeight: 0.12,
                occupiesLayout: false
            ), ControlCapabilityDescriptor(
                id: .trackpad,
                outputKind: .vector2,
                events: [.began, .changed, .ended, .pinchChanged],
                displayName: "Trackpad",
                systemImage: "hand.draw",
                summary: "Drag and pinch gestures",
                defaultWidth: 0.44,
                defaultHeight: 0.32,
                occupiesLayout: true
            ), ControlCapabilityDescriptor(
                id: .pinchPad,
                outputKind: .none,
                events: PinchDirection.allCases.map(\.event),
                displayName: "Pinch Pad",
                systemImage: "plus.magnifyingglass",
                summary: "Pinch in / out shortcuts",
                defaultWidth: 0.36,
                defaultHeight: 0.28,
                occupiesLayout: true
            ), ControlCapabilityDescriptor(
                id: .rotationPad,
                outputKind: .none,
                events: RotationDirection.allCases.map(\.event),
                displayName: "Rotate Pad",
                systemImage: "arrow.triangle.2.circlepath",
                summary: "Rotate clockwise / counterclockwise",
                defaultWidth: 0.36,
                defaultHeight: 0.28,
                occupiesLayout: true
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
            ), ActionCapabilityDescriptor(
                id: .mouseDrag,
                acceptedInputKinds: [.vector2]
            ), ActionCapabilityDescriptor(
                id: .scroll,
                acceptedInputKinds: [.vector2]
            )]
        )
        XCTAssertEqual(ControllerCapabilityCatalog.current.buttonFaces, ButtonFace.allCases)
        XCTAssertEqual(ControllerCapabilityCatalog.current.motionSources, [.tilt])
    }

    func testValidButtonControllerPassesValidation() {
        XCTAssertNoThrow(try SchemaValidator.validate(makeDocument()))
    }

    func testButtonPressAndReleaseUseExistingKeyBinding() throws {
        let document = makeDocument()
        for kind in [ControlEventKind.began, .ended] {
            let event = ControlEvent(
                controllerID: document.id,
                revision: document.revision,
                controlID: "next",
                event: kind,
                sequence: kind == .began ? 1 : 2,
                timestamp: Date(),
                value: .none
            )
            XCTAssertEqual(try SchemaValidator.binding(for: event, in: document).id, "next-binding")
        }
    }

    func testTrackpadDragAndPinchRouteToSeparateActions() throws {
        let bindings = [
            ControlBinding(
                id: "pad-drag",
                controlID: "pad",
                event: .changed,
                action: .mouseDrag(MouseDragAction(
                    gain: 12, deadZone: 0, button: .middle, modifiers: []
                ))
            ),
            ControlBinding(
                id: "pad-zoom",
                controlID: "pad",
                event: .pinchChanged,
                action: .scroll(ScrollAction(gain: 10))
            ),
        ]
        let document = makeDocument(
            controls: [.trackpad(id: "pad", label: "Navigate")],
            items: [ControllerLayoutItem(
                controlID: "pad",
                frame: LayoutRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )],
            bindings: bindings
        )
        try SchemaValidator.validate(document)

        for (index, kind) in [ControlEventKind.began, .changed, .ended, .pinchChanged].enumerated() {
            let event = ControlEvent(
                controllerID: document.id,
                revision: document.revision,
                controlID: "pad",
                event: kind,
                sequence: UInt64(index + 1),
                timestamp: Date(),
                value: .vector2(Vector2Value(x: 0, y: 0.25))
            )
            XCTAssertEqual(
                try SchemaValidator.binding(for: event, in: document).id,
                kind == .pinchChanged ? "pad-zoom" : "pad-drag"
            )
        }

        let encoded = try WireCodec.encoder.encode(WireMessage.schemaSnapshot(document))
        XCTAssertEqual(
            try WireCodec.decoder.decode(WireMessage.self, from: encoded),
            .schemaSnapshot(document)
        )
        let missingZoom = makeDocument(
            controls: document.controls,
            items: document.layout.items,
            bindings: [bindings[0]]
        )
        XCTAssertThrowsError(try SchemaValidator.validate(missingZoom))
    }

    func testPinchAndRotationRequireSeparateMappings() throws {
        let pinchBindings = PinchDirection.allCases.map { direction in
            ControlBinding(
                id: "pinch-\(direction.rawValue)",
                controlID: "pinch",
                event: direction.event,
                action: .keyChord(KeyChordAction(key: .space, modifiers: []))
            )
        }
        let rotationBindings = RotationDirection.allCases.map { direction in
            ControlBinding(
                id: "rotation-\(direction.rawValue)",
                controlID: "rotation",
                event: direction.event,
                action: .keyChord(KeyChordAction(key: .enter, modifiers: []))
            )
        }
        let controls: [ControlDefinition] = [
            .pinchPad(id: "pinch", label: "Pinch"),
            .rotationPad(id: "rotation", label: "Rotate"),
        ]
        let items = controls.enumerated().map { index, control in
            ControllerLayoutItem(
                controlID: control.id,
                frame: LayoutRect(x: 0.05, y: 0.05 + Double(index) * 0.45, width: 0.9, height: 0.4)
            )
        }
        let document = makeDocument(
            controls: controls,
            items: items,
            bindings: pinchBindings + rotationBindings
        )
        try SchemaValidator.validate(document)
        let encoded = try WireCodec.encoder.encode(WireMessage.schemaSnapshot(document))
        XCTAssertEqual(
            try WireCodec.decoder.decode(WireMessage.self, from: encoded),
            .schemaSnapshot(document)
        )

        let incomplete = makeDocument(
            controls: controls,
            items: items,
            bindings: pinchBindings + Array(rotationBindings.dropLast())
        )
        XCTAssertThrowsError(try SchemaValidator.validate(incomplete))
    }

    func testDuplicateControlIDsAreRejected() {
        let document = makeDocument(
            controls: [
                .button(id: "next", label: "Next"),
                .button(id: "next", label: "Duplicate"),
            ],
            items: [
                ControllerLayoutItem(controlID: "next", frame: LayoutRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2)),
            ]
        )

        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testLayoutMustReferenceEveryControl() {
        let document = makeDocument(items: [])

        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testLandscapeLayoutMustReferenceEveryControl() {
        let document = makeDocument(landscapeItems: [])

        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    func testInvalidAbsoluteFrameIsRejected() {
        let document = makeDocument(
            items: [ControllerLayoutItem(
                controlID: "next",
                frame: LayoutRect(x: 0.9, y: 0.1, width: 0.5, height: 0.2)
            )]
        )
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
                ControllerLayoutItem(controlID: "a", frame: LayoutRect(x: 0.05, y: 0.05, width: 0.4, height: 0.25)),
                ControllerLayoutItem(controlID: "stick", frame: LayoutRect(x: 0.55, y: 0.05, width: 0.4, height: 0.55)),
                ControllerLayoutItem(controlID: "tilt", frame: LayoutRect(x: 0.05, y: 0.7, width: 0.9, height: 0.25)),
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
            items: [ControllerLayoutItem(
                controlID: "stick",
                frame: LayoutRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )],
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
                ControllerLayoutItem(controlID: "next", frame: LayoutRect(x: 0.05, y: 0.1, width: 0.4, height: 0.3)),
                ControllerLayoutItem(controlID: "other", frame: LayoutRect(x: 0.55, y: 0.1, width: 0.4, height: 0.3)),
            ]
        )
        XCTAssertThrowsError(try SchemaValidator.validate(document))
    }

    private func makeDocument(
        controls: [ControlDefinition] = [.button(id: "next", label: "Next")],
        items: [ControllerLayoutItem] = [
            ControllerLayoutItem(controlID: "next", frame: LayoutRect(x: 0.1, y: 0.35, width: 0.8, height: 0.3)),
        ],
        landscapeItems: [ControllerLayoutItem]? = nil,
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
            preferredOrientation: .portrait,
            layouts: ControllerLayouts(
                portrait: ControllerLayout(items: items),
                landscape: ControllerLayout(items: landscapeItems ?? items)
            ),
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
