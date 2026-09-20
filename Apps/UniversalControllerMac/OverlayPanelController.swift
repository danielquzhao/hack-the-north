import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let contextMonitor: AppContextMonitor
    private let pairingHost = PairingSessionHost()
    private let editorState = ControllerEditorState()
    private let generator: ControllerGenerating = OpenAIControllerGenerator()
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?
    private var generationTargetBundleID: String?
    private var panel: OverlayPanel?
    private var lastPanelOrigin: NSPoint?
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private var actionRouter: ControllerActionRouter?
    private var pendingControlEvent: Task<Void, Never>?

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
        if editorState.draft?.target.bundleIdentifier != context?.application.bundleIdentifier {
            editorState.draft = nil
            editorState.selectedControlID = nil
            editorState.draftWasGenerated = false
            editorState.isIterativePrompt = false
            editorState.layoutDirty = false
        }
        if editorState.isGenerating,
           generationTargetBundleID != context?.application.bundleIdentifier {
            generationTask?.cancel()
            generationTask = nil
            generationID = nil
            editorState.isGenerating = false
            editorState.generationStatus = nil
        }
        let panel = makePanel(context: context, errorMessage: errorMessage)
        self.panel = panel
        if let lastPanelOrigin {
            panel.setFrameOrigin(lastPanelOrigin)
        } else {
            center(panel)
        }
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if editorState.capturingShortcutControlID != nil {
                return event
            }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    func close() {
        if let panel {
            lastPanelOrigin = panel.frame.origin
        }
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
        let initialWidth: CGFloat = editorState.draft == nil ? 430 : 1100
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 760),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: MacOverlayView(
            context: context,
            errorMessage: errorMessage,
            pairingHost: pairingHost,
            editorState: editorState,
            onClose: { [weak self] in self?.close() },
            onRequestPermission: { MacActionExecutor.requestNextPermission() },
            onMakeDraft: { [weak self] style, includeTilt in
                self?.makeController(context: context, style: style, includeTilt: includeTilt)
            },
            onGenerate: { [weak self] request in
                self?.startGeneration(request: request, context: context)
            },
            onSaveAPIKey: { [weak self] key in
                self?.saveAPIKey(key)
            },
            onRemoveAPIKey: { [weak self] in
                self?.removeAPIKey()
            },
            onStartPairing: { [weak self] controller in
                self?.startPairing(context: context, controller: controller)
            },
            onNextSlide: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.sendNextSlide(context: context)
                }
            },
            onWorkspaceExpansionChanged: { [weak self] expanded in
                self?.setWorkspaceExpanded(expanded)
            },
            onApplyLayout: { [weak self] document in
                self?.applyLayout(document)
            }
        ))
        return panel
    }

    private func setWorkspaceExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let targetWidth: CGFloat = expanded ? 1100 : 430
        guard abs(panel.frame.width - targetWidth) > 1 else { return }

        let currentFrame = panel.frame
        let screen = NSScreen.screens.first {
            $0.frame.intersects(currentFrame)
        } ?? NSScreen.main
        var targetFrame = NSRect(
            x: currentFrame.midX - targetWidth / 2,
            y: currentFrame.minY,
            width: targetWidth,
            height: 760
        )
        if let visibleFrame = screen?.visibleFrame {
            targetFrame.origin.x = min(
                max(targetFrame.minX, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - targetWidth)
            )
            targetFrame.origin.y = min(
                max(targetFrame.minY, visibleFrame.minY),
                max(visibleFrame.minY, visibleFrame.maxY - targetFrame.height)
            )
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                if let panel {
                    self?.lastPanelOrigin = panel.frame.origin
                }
            }
        }
    }

    private func makeController(
        context: AppContext?,
        style: DemoControllerStyle,
        includeTilt: Bool
    ) -> ControllerDocument? {
        guard let application = context?.application,
              MacActionExecutor.isKeynote(application),
              let bundleID = application.bundleIdentifier else {
            return nil
        }
        let target = ControllerTarget(
            bundleIdentifier: bundleID,
            displayName: context?.displayName ?? "Keynote"
        )
        switch style {
        case .presenter:
            return makePresenterController(target: target)
        case .gamepad:
            return makeGamepadController(target: target, includeTilt: includeTilt)
        }
    }

    private func startPairing(context: AppContext?, controller: ControllerDocument) {
        guard !editorState.isGenerating,
              context?.application.bundleIdentifier == controller.target.bundleIdentifier else {
            return
        }
        pairingHost.startSession(controller: controller)
        guard let application = context?.application,
              let router = try? ControllerActionRouter(
                  document: controller,
                  application: application
              ) else {
            actionRouter = nil
            return
        }
        installActionRouter(router, context: context)
    }

    private func applyLayout(_ document: ControllerDocument) -> String? {
        do {
            try pairingHost.publishController(document)
            if let application = contextMonitor.capture()?.application,
               application.bundleIdentifier == document.target.bundleIdentifier,
               let router = try? ControllerActionRouter(
                   document: document,
                   application: application
               ) {
                installActionRouter(router, context: contextMonitor.capture())
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func installActionRouter(_ router: ControllerActionRouter, context: AppContext?) {
        actionRouter?.deactivate()
        actionRouter = router
        pairingHost.onConnectionEnded = { [weak self] in
            self?.actionRouter?.deactivate()
            self?.actionRouter = nil
            self?.pendingControlEvent = nil
        }
        pairingHost.onControlEvent = { [weak self] event in
            guard let self else { return }
            let previous = pendingControlEvent
            pendingControlEvent = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, let router = self.actionRouter else { return }
                await self.route(event, using: router, context: context)
            }
        }
    }

    private func saveAPIKey(_ key: String) -> String? {
        do {
            try OpenAIAPIKeyStore.save(key)
            editorState.hasAPIKey = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func removeAPIKey() {
        OpenAIAPIKeyStore.remove()
        editorState.hasAPIKey = false
    }

    private func startGeneration(request: String, context: AppContext?) {
        guard !editorState.isGenerating,
              let application = context?.application,
              let bundleIdentifier = application.bundleIdentifier else { return }
        let generationContext = ControllerGenerationContext(
            bundleIdentifier: bundleIdentifier,
            appName: context?.displayName ?? application.localizedName ?? "Mac app",
            windowTitle: context?.windowTitle
        )
        editorState.isGenerating = true
        editorState.generationStatus = "Capturing window…"
        editorState.generationError = nil
        generationTargetBundleID = bundleIdentifier
        let generationID = UUID()
        let existingDocument = editorState.isIterativePrompt ? editorState.draft : nil
        self.generationID = generationID
        generationTask = Task { @MainActor [weak self] in
            await self?.generate(
                request: request,
                context: generationContext,
                application: application,
                windowTitle: context?.windowTitle,
                windowFrame: context?.windowFrame,
                existingDocument: existingDocument,
                id: generationID
            )
        }
    }

    private func generate(
        request: String,
        context: ControllerGenerationContext,
        application: NSRunningApplication,
        windowTitle: String?,
        windowFrame: CGRect?,
        existingDocument: ControllerDocument?,
        id: UUID
    ) async {
        defer {
            if generationID == id {
                editorState.isGenerating = false
                editorState.generationStatus = nil
                generationTask = nil
                generationID = nil
                generationTargetBundleID = nil
            }
        }
        do {
            guard let apiKey = OpenAIAPIKeyStore.load() else {
                throw ControllerGenerationError.missingKey
            }
            let screenshotJPEG = try await TargetWindowScreenshot.captureJPEG(
                of: application,
                title: windowTitle,
                frame: windowFrame
            )
            try Task.checkCancellation()
            guard generationID == id else { return }
            editorState.generationStatus = "Generating…"
            let document = try await generator.generate(
                request: request,
                context: context,
                screenshotJPEG: screenshotJPEG,
                apiKey: apiKey,
                existingDocument: existingDocument
            )
            try Task.checkCancellation()
            guard generationID == id else { return }
            editorState.draft = document
            editorState.selectedControlID = document.layout.items.first?.controlID
            editorState.draftWasGenerated = true
            editorState.isIterativePrompt = true
            editorState.layoutDirty = false
            editorState.generationError = nil
            editorState.prompt = ""
        } catch is CancellationError {
            return
        } catch {
            if generationID == id {
                editorState.generationError = error.localizedDescription
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
            preferredOrientation: .landscape,
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
        var portraitSpecs: [(String, Int, Int)] = [("stick", 2, 2)]
        portraitSpecs += buttons.map { ($0.id, 1, 1) }
        var landscapeSpecs: [(String, Int, Int)] = [("stick", 2, 2)]
        landscapeSpecs += buttons.map { ($0.id, 1, 1) }
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
            portraitSpecs.append(("tilt", 2, 1))
            landscapeSpecs.append(("tilt", 2, 1))
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
            preferredOrientation: .landscape,
            layouts: ControllerLayouts(
                portrait: AbsoluteLayoutBuilder.fromGrid(columns: 2, specs: portraitSpecs),
                landscape: AbsoluteLayoutBuilder.fromGrid(columns: 4, specs: landscapeSpecs)
            ),
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

    private var windowDragMouseStart: NSPoint?
    private var windowDragOriginStart: NSPoint?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            windowDragMouseStart = NSEvent.mouseLocation
            windowDragOriginStart = frame.origin
            return
        case .rightMouseDragged:
            if let mouseStart = windowDragMouseStart, let originStart = windowDragOriginStart {
                let current = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(
                    x: originStart.x + (current.x - mouseStart.x),
                    y: originStart.y + (current.y - mouseStart.y)
                ))
            }
            return
        case .rightMouseUp:
            windowDragMouseStart = nil
            windowDragOriginStart = nil
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}
