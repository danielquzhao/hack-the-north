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
            )]
        )
        XCTAssertEqual(
            ControllerCapabilityCatalog.current.actions,
            [ActionCapabilityDescriptor(
                id: .keyChord,
                acceptedInputKinds: [.none]
            )]
        )
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

    private func makeDocument(
        controls: [ControlDefinition] = [.button(id: "next", label: "Next")],
        items: [ControllerLayoutItem] = [
            ControllerLayoutItem(controlID: "next", columnSpan: 1, rowSpan: 1),
        ]
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
            bindings: [ControlBinding(
                id: "next-binding",
                controlID: "next",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .rightArrow, modifiers: []))
            )]
        )
    }
}
