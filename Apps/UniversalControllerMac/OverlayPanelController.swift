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
    private var actionRouters: [Int: ControllerActionRouter] = [:]
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
        if editorState.sessionPack?.target.bundleIdentifier != context?.application.bundleIdentifier {
            editorState.sessionPack = nil
            editorState.selectedSeatIndex = 0
            editorState.selectedControlID = nil
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
        let initialSize = editorState.draft == nil || editorState.isOnMainPage
            ? OverlayPanelLayout.mainSize : OverlayPanelLayout.workspaceSize
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
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
            onReturnToMain: { [weak self] in self?.returnToMainPage() },
            onRequestPermission: { MacActionExecutor.requestNextPermission() },
            onGenerate: { [weak self] request in
                self?.startGeneration(request: request, context: context)
            },
            onSaveAPIKey: { [weak self] key in
                self?.saveAPIKey(key)
            },
            onRemoveAPIKey: { [weak self] in
                self?.removeAPIKey()
            },
            onStartPairing: { [weak self] pack in
                self?.startPairing(context: context, pack: pack)
            },
            onNextSlide: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.sendNextSlide(context: context)
                }
            },
            onWorkspaceExpansionChanged: { [weak self] expanded in
                self?.setWorkspaceExpanded(expanded)
            },
            onApplyLayout: { [weak self] pack in
                self?.applyLayout(pack)
            }
        ))
        return panel
    }

    private func returnToMainPage() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        generationTargetBundleID = nil
        pendingControlEvent?.cancel()
        pendingControlEvent = nil
        pairingHost.stopSession()
        clearActionRouters()
        editorState.resetToMainPage()
    }

    private func setWorkspaceExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let targetSize = expanded ? OverlayPanelLayout.workspaceSize : OverlayPanelLayout.mainSize
        guard abs(panel.frame.width - targetSize.width) > 1 ||
              abs(panel.frame.height - targetSize.height) > 1 else { return }

        let currentFrame = panel.frame
        let screen = NSScreen.screens.first {
            $0.frame.intersects(currentFrame)
        } ?? NSScreen.main
        var targetFrame = NSRect(
            x: currentFrame.midX - targetSize.width / 2,
            y: currentFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        if let visibleFrame = screen?.visibleFrame {
            targetFrame.origin.x = min(
                max(targetFrame.minX, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - targetSize.width)
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

    private func startPairing(context: AppContext?, pack: ControllerSessionPack) {
        guard !editorState.isGenerating,
              context?.application.bundleIdentifier == pack.target.bundleIdentifier else {
            return
        }
        pairingHost.startSession(pack: pack)
        guard let application = context?.application else {
            clearActionRouters()
            return
        }
        installActionRouters(for: pack, application: application, context: context)
    }

    private func applyLayout(_ pack: ControllerSessionPack) -> String? {
        do {
            try pairingHost.publishPack(pack)
            if let application = contextMonitor.capture()?.application,
               application.bundleIdentifier == pack.target.bundleIdentifier {
                installActionRouters(
                    for: pack,
                    application: application,
                    context: contextMonitor.capture()
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func installActionRouters(
        for pack: ControllerSessionPack,
        application: NSRunningApplication,
        context: AppContext?
    ) {
        clearActionRouters()
        var routers: [Int: ControllerActionRouter] = [:]
        for seat in pack.seats {
            guard let router = try? ControllerActionRouter(
                document: seat.controller,
                application: application
            ) else { continue }
            routers[seat.index] = router
        }
        actionRouters = routers
        pairingHost.onConnectionEnded = { [weak self] in
            self?.clearActionRouters()
            self?.pendingControlEvent = nil
        }
        pairingHost.onControlEvent = { [weak self] seatIndex, event in
            guard let self else { return }
            let previous = pendingControlEvent
            pendingControlEvent = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, let router = self.actionRouters[seatIndex] else { return }
                await self.route(event, using: router, context: context)
            }
        }
    }

    private func clearActionRouters() {
        for router in actionRouters.values {
            router.deactivate()
        }
        actionRouters.removeAll()
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
            windowTitle: context?.windowTitle,
            playerCount: editorState.playerCount
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
            let pack = try await generator.generate(
                request: request,
                context: context,
                screenshotJPEG: screenshotJPEG,
                apiKey: apiKey,
                existingDocument: existingDocument
            )
            try Task.checkCancellation()
            guard generationID == id else { return }
            editorState.loadGenerated(pack)
        } catch is CancellationError {
            return
        } catch {
            if generationID == id {
                editorState.generationError = error.localizedDescription
            }
        }
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
            router.cancelActiveDrag()
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
