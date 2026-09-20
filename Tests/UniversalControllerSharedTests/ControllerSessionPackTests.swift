import Foundation
import XCTest
@testable import UniversalControllerShared

final class ControllerSessionPackTests: XCTestCase {
    func testSinglePackValidates() throws {
        let pack = ControllerSessionPack.single(makeDocument())
        XCTAssertEqual(pack.seatCount, 1)
        try SchemaValidator.validate(pack)
    }

    func testAddSeatClonesLayoutAndUsesUniqueControllerID() throws {
        var pack = ControllerSessionPack.single(makeDocument())
        let second = try pack.addSeat()
        XCTAssertEqual(second, 1)
        XCTAssertEqual(pack.seatCount, 2)
        XCTAssertEqual(pack.seats[0].controller.layouts, pack.seats[1].controller.layouts)
        XCTAssertEqual(pack.seats[0].controller.controls, pack.seats[1].controller.controls)
        XCTAssertNotEqual(pack.seats[0].controller.id, pack.seats[1].controller.id)
        try SchemaValidator.validate(pack)
    }

    func testSharedChromeSyncPreservesPerSeatBindings() throws {
        var pack = ControllerSessionPack.single(makeDocument())
        _ = try pack.addSeat()
        pack.updateBindings(
            [ControlBinding(
                id: "next-binding",
                controlID: "next",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .letterW, modifiers: []))
            )],
            at: 0
        )
        pack.updateBindings(
            [ControlBinding(
                id: "next-binding",
                controlID: "next",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .upArrow, modifiers: []))
            )],
            at: 1
        )
        pack.updateSharedChrome(name: "Local Co-op")
        XCTAssertEqual(pack.name, "Local Co-op")
        XCTAssertEqual(pack.seats[0].controller.name, "Local Co-op")
        XCTAssertEqual(pack.seats[1].controller.name, "Local Co-op")
        guard case .keyChord(let seat1) = pack.seats[0].controller.bindings[0].action,
              case .keyChord(let seat2) = pack.seats[1].controller.bindings[0].action else {
            return XCTFail("Expected key bindings")
        }
        XCTAssertEqual(seat1.key, .letterW)
        XCTAssertEqual(seat2.key, .upArrow)
        try SchemaValidator.validate(pack)
    }

    func testDuplicateControllerIDsAreRejected() {
        let document = makeDocument()
        let pack = ControllerSessionPack(
            name: "Bad",
            seats: [
                ControllerSeat(index: 0, label: "Player 1", controller: document),
                ControllerSeat(index: 1, label: "Player 2", controller: document),
            ]
        )
        XCTAssertThrowsError(try SchemaValidator.validate(pack))
    }

    private func makeDocument() -> ControllerDocument {
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
                portrait: ControllerLayout(items: [
                    ControllerLayoutItem(
                        controlID: "next",
                        frame: LayoutRect(x: 0.1, y: 0.35, width: 0.8, height: 0.3)
                    ),
                ]),
                landscape: ControllerLayout(items: [
                    ControllerLayoutItem(
                        controlID: "next",
                        frame: LayoutRect(x: 0.1, y: 0.35, width: 0.8, height: 0.3)
                    ),
                ])
            ),
            controls: [.button(id: "next", label: "Next")],
            bindings: [ControlBinding(
                id: "next-binding",
                controlID: "next",
                event: .triggered,
                action: .keyChord(KeyChordAction(key: .rightArrow, modifiers: []))
            )]
        )
    }
}
