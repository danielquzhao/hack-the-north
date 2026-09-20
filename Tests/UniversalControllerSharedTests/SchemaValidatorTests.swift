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
                id: .dpad,
                outputKind: .none,
                events: [.upBegan, .upEnded, .downBegan, .downEnded,
                         .leftBegan, .leftEnded, .rightBegan, .rightEnded],
                displayName: "D-pad",
                systemImage: "dpad.fill",
                summary: "Four independently mapped directions",
                defaultWidth: 0.36,
                defaultHeight: 0.36,
                occupiesLayout: true
            ), ControlCapabilityDescriptor(
                id: .joystick,
                outputKind: .vector2,
                events: [.changed],
                displayName: "Joystick",
                systemImage: "circle.circle",
                summary: "Move the pointer or hold directional keys",
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
                id: .directionalKeys,
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
        XCTAssertEqual(ControlCapabilityID.allCases, [.button, .dpad, .joystick, .motion, .trackpad])
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

    func testDPadRequiresFourMappingsAndRoutesPressAndRelease() throws {
        let bindings: [ControlBinding] = [
            (.upBegan, .upArrow), (.downBegan, .downArrow),
            (.leftBegan, .leftArrow), (.rightBegan, .rightArrow),
        ].map { event, key in
            ControlBinding(id: event.rawValue, controlID: "pad", event: event,
                           action: .keyChord(KeyChordAction(key: key, modifiers: [])))
        }
        let document = makeDocument(
            controls: [.dpad(id: "pad", label: "Movement")],
            items: [ControllerLayoutItem(controlID: "pad", frame: LayoutRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))],
            bindings: bindings
        )
        XCTAssertNoThrow(try SchemaValidator.validate(document))
        for (event, expected) in [(ControlEventKind.upBegan, "upBegan"),
                                  (.upEnded, "upBegan"),
                                  (.leftBegan, "leftBegan"),
                                  (.leftEnded, "leftBegan")] {
            let input = ControlEvent(controllerID: document.id, revision: document.revision,
                                     controlID: "pad", event: event, sequence: 1,
                                     timestamp: Date(), value: .none)
            XCTAssertEqual(try SchemaValidator.binding(for: input, in: document).id, expected)
        }
        XCTAssertThrowsError(try SchemaValidator.validate(makeDocument(
            controls: document.controls, items: document.layout.items,
            bindings: Array(bindings.dropLast())
        )))
        let encoded = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(ControllerDocument.self, from: encoded), document)
    }

    func testExplicitGridPlacementKeepsIndependentPositions() throws {
        let layout = try ControllerLayoutGrid.layout(for: .landscape, placements: [
            ControllerGridPlacement(controlID: "pad", kind: .dpad,
                                    column: 1, row: 2, columnSpan: 5, rowSpan: 6),
            ControllerGridPlacement(controlID: "next", kind: .button,
                                    column: 15, row: 3, columnSpan: 3, rowSpan: 3),
        ])
        XCTAssertEqual(layout.items[0].frame.x, 1.0 / 20 + 0.008, accuracy: 0.0001)
        XCTAssertEqual(layout.items[0].frame.y, 2.0 / 10 + 0.008, accuracy: 0.0001)
        XCTAssertEqual(layout.items[1].frame.x, 15.0 / 20 + 0.008, accuracy: 0.0001)
    }

    func testGridRejectsOverlapAndOutOfBoundsPlacement() {
        let pad = ControllerGridPlacement(controlID: "pad", kind: .dpad,
                                          column: 1, row: 2, columnSpan: 5, rowSpan: 6)
        XCTAssertThrowsError(try ControllerLayoutGrid.layout(for: .landscape, placements: [
            pad,
            ControllerGridPlacement(controlID: "button", kind: .button,
                                    column: 4, row: 3, columnSpan: 3, rowSpan: 2),
        ]))
        XCTAssertThrowsError(try ControllerLayoutGrid.layout(for: .landscape, placements: [
            ControllerGridPlacement(controlID: "outside", kind: .dpad,
                                    column: 18, row: 3, columnSpan: 3, rowSpan: 3),
        ]))
    }

    func testDPadVisibleFrameTightensWideLayoutArea() {
        let original = LayoutRect(x: 0.02, y: 0.05, width: 0.94, height: 0.91)
        let frame = ControllerLayoutGeometry.visibleFrame(
            for: ControlDefinition.dpad(id: "pad", label: "Move").kind,
            in: original,
            canvasWidth: 600,
            canvasHeight: 300
        )
        XCTAssertLessThan(frame.width, original.width / 2)
        XCTAssertEqual(frame.width * 600 + 24, frame.height * 300, accuracy: 0.01)
        XCTAssertEqual(frame.x + frame.width / 2, original.x + original.width / 2, accuracy: 0.001)
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
                ControllerLayoutItem(controlID: "tilt", frame: ControllerCapabilityCatalog.offCanvasSensorFrame),
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

    func testDirectionalJoystickSupportsDiagonalsAndReleasesAtCenter() throws {
        let action = DirectionalKeysAction(
            up: KeyChordAction(key: .letterW, modifiers: []),
            down: KeyChordAction(key: .letterS, modifiers: []),
            left: KeyChordAction(key: .letterA, modifiers: []),
            right: KeyChordAction(key: .letterD, modifiers: []),
            deadZone: 0.2
        )
        let document = makeDocument(
            controls: [.joystick(id: "stick", label: "Move")],
            items: [ControllerLayoutItem(
                controlID: "stick",
                frame: LayoutRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )],
            bindings: [ControlBinding(
                id: "stick-directions",
                controlID: "stick",
                event: .changed,
                action: .directionalKeys(action)
            )]
        )
        try SchemaValidator.validate(document)
        XCTAssertEqual(action.activeDirections(for: Vector2Value(x: 0.7, y: 0.8)), [.up, .right])
        XCTAssertEqual(action.activeDirections(for: Vector2Value(x: 0, y: 0)), [])
        XCTAssertEqual(try JSONDecoder().decode(ControllerDocument.self, from: JSONEncoder().encode(document)), document)
    }

    func testDirectionalJoystickRejectsInvalidDeadZone() {
        let document = makeDocument(
            controls: [.joystick(id: "stick", label: "Move")],
            items: [ControllerLayoutItem(
                controlID: "stick",
                frame: LayoutRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )],
            bindings: [ControlBinding(
                id: "stick-directions",
                controlID: "stick",
                event: .changed,
                action: .directionalKeys(DirectionalKeysAction(
                    up: KeyChordAction(key: .upArrow, modifiers: []),
                    down: KeyChordAction(key: .downArrow, modifiers: []),
                    left: KeyChordAction(key: .leftArrow, modifiers: []),
                    right: KeyChordAction(key: .rightArrow, modifiers: []),
                    deadZone: 0.9
                ))
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
