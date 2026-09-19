import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let contextMonitor: AppContextMonitor
    private let pairingHost = PairingSessionHost()
    private var panel: OverlayPanel?
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?

    init(contextMonitor: AppContextMonitor) {
        self.contextMonitor = contextMonitor
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            open()
        }
    }

    private func open() {
        let context = contextMonitor.capture()
        open(context: context, errorMessage: nil)
    }

    private func open(context: AppContext?, errorMessage: String?) {
        let panel = makePanel(context: context, errorMessage: errorMessage)
        self.panel = panel
        center(panel)
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    func close() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel(context: AppContext?, errorMessage: String?) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: MacOverlayView(
            context: context,
            errorMessage: errorMessage,
            pairingHost: pairingHost,
            onClose: { [weak self] in self?.close() },
            onRequestPermission: { MacActionExecutor.requestNextPermission() },
            onStartPairing: { [weak self] style, includeTilt in
                self?.startPairing(context: context, style: style, includeTilt: includeTilt)
            },
            onNextSlide: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.sendNextSlide(context: context)
                }
            }
        ))
        return panel
    }

    private func startPairing(
        context: AppContext?,
        style: DemoControllerStyle,
        includeTilt: Bool
    ) {
        let controller: ControllerDocument?
        if let application = context?.application,
           MacActionExecutor.isKeynote(application),
           let bundleID = application.bundleIdentifier {
            let target = ControllerTarget(
                bundleIdentifier: bundleID,
                displayName: context?.displayName ?? "Keynote"
            )
            switch style {
            case .presenter:
                controller = makePresenterController(target: target)
            case .gamepad:
                controller = makeGamepadController(target: target, includeTilt: includeTilt)
            }
        } else {
            controller = nil
        }

        pairingHost.startSession(controller: controller)
        if let controller, let application = context?.application,
           let router = try? ControllerActionRouter(
               document: controller,
               application: application
           ) {
            pairingHost.onControlEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.route(event, using: router, context: context)
                }
            }
        }
    }

    private func makePresenterController(target: ControllerTarget) -> ControllerDocument {
        ControllerDocument(
                schemaVersion: ControllerDocument.currentSchemaVersion,
                id: UUID(),
                revision: 1,
                name: "Keynote Presenter",
                target: target,
                layout: ControllerLayout(
                    columns: 1,
                    items: [ControllerLayoutItem(
                        controlID: "next-slide",
                        columnSpan: 1,
                        rowSpan: 1
                    )]
                ),
                controls: [
                    .button(id: "next-slide", label: "Next Slide"),
                ],
                bindings: [
                    ControlBinding(
                        id: "next-slide-binding",
                        controlID: "next-slide",
                        event: .triggered,
                        action: .keyChord(KeyChordAction(
                            key: .rightArrow,
                            modifiers: []
                        ))
                    ),
                ]
            )
    }

    private func makeGamepadController(
        target: ControllerTarget,
        includeTilt: Bool
    ) -> ControllerDocument {
        let buttons: [(id: String, label: String, face: ButtonFace, key: SemanticKey)] = [
            ("x", "Blackout", .x, .letterB),
            ("y", "Advance", .y, .space),
            ("a", "Next", .a, .rightArrow),
            ("b", "Previous", .b, .leftArrow),
        ]
        var controls = [ControlDefinition.joystick(id: "stick", label: "Pointer")]
        controls += buttons.map { .button(id: $0.id, label: $0.label, face: $0.face) }
        var items = [ControllerLayoutItem(controlID: "stick", columnSpan: 2, rowSpan: 2)]
        items += buttons.map { ControllerLayoutItem(controlID: $0.id, columnSpan: 1, rowSpan: 1) }
        var bindings = [ControlBinding(
            id: "stick-move",
            controlID: "stick",
            event: .changed,
            action: .mouseMove(MouseMoveAction(gain: 14, deadZone: 0.1))
        )]
        bindings += buttons.map {
            ControlBinding(
                id: "\($0.id)-press",
                controlID: $0.id,
                event: .triggered,
                action: .keyChord(KeyChordAction(key: $0.key, modifiers: []))
            )
        }

        if includeTilt {
            controls.append(.tilt(id: "tilt", label: "Tilt Pointer"))
            items.append(ControllerLayoutItem(controlID: "tilt", columnSpan: 2, rowSpan: 1))
            bindings.append(ControlBinding(
                id: "tilt-move",
                controlID: "tilt",
                event: .changed,
                action: .mouseMove(MouseMoveAction(gain: 9, deadZone: 0.18))
            ))
        }

        return ControllerDocument(
            schemaVersion: ControllerDocument.currentSchemaVersion,
            id: UUID(),
            revision: 1,
            name: "Keynote Gamepad",
            target: target,
            layout: ControllerLayout(columns: 2, items: items),
            controls: controls,
            bindings: bindings
        )
    }

    private func route(
        _ event: ControlEvent,
        using router: ControllerActionRouter,
        context: AppContext?
    ) async {
        if case .vector2(let value) = event.value,
           let binding = try? SchemaValidator.binding(for: event, in: router.document),
           case .mouseMove(let action) = binding.action,
           abs(value.x) <= action.deadZone,
           abs(value.y) <= action.deadZone {
            return
        }
        close()
        do {
            try await router.handle(event)
        } catch {
            open(context: context, errorMessage: error.localizedDescription)
        }
    }

    private func sendNextSlide(context: AppContext?) async {
        guard let context else { return }
        close()
        do {
            try await MacActionExecutor.sendNextSlide(to: context.application)
        } catch {
            open(context: context, errorMessage: error.localizedDescription)
        }
    }

    private func center(_ panel: NSPanel) {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
