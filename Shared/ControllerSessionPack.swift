import Foundation

/// One phone seat in a multi-device session. Each seat has its own controller ID and
/// bindings so Player 1 / Player 2 can map to different keys while sharing layout chrome.
struct ControllerSeat: Codable, Equatable, Sendable, Identifiable {
    var id: Int { index }

    /// Zero-based seat order. First phone to pair claims the lowest free index.
    let index: Int
    let label: String
    var controller: ControllerDocument
}

/// Mac-side session: one QR, N seat schemas. Phones still receive a single `ControllerDocument`.
struct ControllerSessionPack: Codable, Equatable, Sendable {
    static let maximumSeats = 4

    var name: String
    var seats: [ControllerSeat]

    var seatCount: Int { seats.count }

    var target: ControllerTarget {
        seats[0].controller.target
    }

    init(name: String, seats: [ControllerSeat]) {
        self.name = name
        self.seats = seats.sorted { $0.index < $1.index }
    }

    static func single(_ document: ControllerDocument) -> ControllerSessionPack {
        ControllerSessionPack(
            name: document.name,
            seats: [ControllerSeat(index: 0, label: "Player 1", controller: document)]
        )
    }

    func seat(at index: Int) -> ControllerSeat? {
        seats.first { $0.index == index }
    }

    func controller(at index: Int) -> ControllerDocument? {
        seat(at: index)?.controller
    }

    /// Shared preview chrome comes from the primary seat; bindings stay per-seat.
    var primaryController: ControllerDocument {
        seats[0].controller
    }

    mutating func setController(_ document: ControllerDocument, at index: Int) {
        guard let seatOffset = seats.firstIndex(where: { $0.index == index }) else { return }
        seats[seatOffset].controller = document
    }

    /// Layout, controls, orientation, and display name stay in sync across seats.
    /// Bindings and controller IDs remain per-seat.
    mutating func updateSharedChrome(
        name: String? = nil,
        preferredOrientation: ControllerOrientation? = nil,
        layouts: ControllerLayouts? = nil,
        controls: [ControlDefinition]? = nil,
        revision: Int? = nil
    ) {
        seats = seats.map { seat in
            var next = seat
            let current = seat.controller
            next.controller = ControllerDocument(
                schemaVersion: current.schemaVersion,
                id: current.id,
                revision: revision ?? current.revision,
                name: name ?? current.name,
                target: current.target,
                preferredOrientation: preferredOrientation ?? current.preferredOrientation,
                layouts: layouts ?? current.layouts,
                controls: controls ?? current.controls,
                bindings: current.bindings
            )
            return next
        }
        if let name {
            self.name = name
        }
    }

    mutating func updateBindings(_ bindings: [ControlBinding], at index: Int, bumpRevision: Bool = false) {
        guard let seatOffset = seats.firstIndex(where: { $0.index == index }) else { return }
        let current = seats[seatOffset].controller
        seats[seatOffset].controller = ControllerDocument(
            schemaVersion: current.schemaVersion,
            id: current.id,
            revision: bumpRevision ? current.revision + 1 : current.revision,
            name: current.name,
            target: current.target,
            preferredOrientation: current.preferredOrientation,
            layouts: current.layouts,
            controls: current.controls,
            bindings: bindings
        )
    }

    mutating func addSeat(copyingBindingsFrom sourceIndex: Int = 0) throws -> Int {
        guard seats.count < Self.maximumSeats else {
            throw SchemaValidationError(reason: "A session can have at most \(Self.maximumSeats) seats.")
        }
        guard let source = controller(at: sourceIndex) ?? seats.first?.controller else {
            throw SchemaValidationError(reason: "Add a controller before creating another seat.")
        }
        let nextIndex = (seats.map(\.index).max() ?? -1) + 1
        let label = "Player \(nextIndex + 1)"
        let cloned = source.cloningForSeat(label: label)
        seats.append(ControllerSeat(index: nextIndex, label: label, controller: cloned))
        seats.sort { $0.index < $1.index }
        return nextIndex
    }

    mutating func removeSeat(at index: Int) throws {
        guard seats.count > 1 else {
            throw SchemaValidationError(reason: "Keep at least one seat.")
        }
        guard seats.contains(where: { $0.index == index }) else { return }
        seats.removeAll { $0.index == index }
        // Reindex so seat order stays compact for pairing assignment.
        seats = seats.sorted { $0.index < $1.index }.enumerated().map { offset, seat in
            ControllerSeat(
                index: offset,
                label: seat.label.hasPrefix("Player ") ? "Player \(offset + 1)" : seat.label,
                controller: seat.controller
            )
        }
    }
}

extension ControllerDocument {
    /// Seat label lives on `ControllerSeat`; keep the shared controller display name.
    func cloningForSeat(label _: String) -> ControllerDocument {
        ControllerDocument(
            schemaVersion: schemaVersion,
            id: UUID(),
            revision: revision,
            name: name,
            target: target,
            preferredOrientation: preferredOrientation,
            layouts: layouts,
            controls: controls,
            bindings: bindings
        )
    }
}
