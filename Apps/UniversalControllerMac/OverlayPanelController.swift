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
            editorState.isIterativePrompt = false
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
        panel.isMovableByWindowBackground = true
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

    private func startPairing(context: AppContext?, controller: ControllerDocument) {
        guard !editorState.isGenerating,
              context?.application.bundleIdentifier == controller.target.bundleIdentifier else {
            return
        }
        pairingHost.startSession(controller: controller)
        if let application = context?.application,
           let router = try? ControllerActionRouter(
               document: controller,
               application: application
           ) {
            pairingHost.onConnectionEnded = { router.deactivate() }
            var pendingEvent: Task<Void, Never>?
            pairingHost.onControlEvent = { [weak self] event in
                let previous = pendingEvent
                pendingEvent = Task { @MainActor [weak self] in
                    await previous?.value
                    await self?.route(event, using: router, context: context)
                }
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
            editorState.isIterativePrompt = true
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
