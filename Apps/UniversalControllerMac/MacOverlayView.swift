import AppKit
import SwiftUI

enum DemoControllerStyle: String, CaseIterable, Identifiable {
    case presenter = "Presenter"
    case gamepad = "Gamepad"

    var id: Self { self }
}

private enum EditorToolTab: String, CaseIterable, Identifiable {
    case controls = "Controls"
    case assets = "Assets"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .controls:
            "slider.horizontal.3"
        case .assets:
            "square.grid.2x2"
        }
    }
}

@MainActor
final class ControllerEditorState: ObservableObject {
    @Published var demoStyle: DemoControllerStyle = .presenter
    @Published var includeTilt = false
    @Published var draft: ControllerDocument?
    @Published var selectedControlID: String?
    @Published var prompt = ""
    @Published var hasAPIKey = OpenAIAPIKeyStore.load() != nil
    @Published var isGenerating = false
    @Published var generationStatus: String?
    @Published var generationError: String?
    @Published var draftWasGenerated = false
    @Published var isIterativePrompt = false
    @Published var layoutDirty = false
}

struct MacOverlayView: View {
    let context: AppContext?
    let errorMessage: String?
    @ObservedObject var pairingHost: PairingSessionHost
    @ObservedObject var editorState: ControllerEditorState
    let onClose: () -> Void
    let onRequestPermission: () -> Void
    let onMakeDraft: (DemoControllerStyle, Bool) -> ControllerDocument?
    let onGenerate: (String) -> Void
    let onSaveAPIKey: (String) -> String?
    let onRemoveAPIKey: () -> Void
    let onStartPairing: (ControllerDocument) -> Void
    let onNextSlide: () -> Void
    let onWorkspaceExpansionChanged: (Bool) -> Void
    let onApplyLayout: (ControllerDocument) -> String?

    @State private var permissionStatus = MacActionExecutor.permissionStatus
    @State private var showKeyboardHelp = false
    @State private var apiKeyEntry = ""
    @State private var apiKeyError: String?
    @State private var showingSettings = true
    @State private var selectedToolTab: EditorToolTab = .controls

    private var demoStyle: DemoControllerStyle {
        get { editorState.demoStyle }
        nonmutating set { editorState.demoStyle = newValue }
    }

    private var includeTilt: Bool {
        get { editorState.includeTilt }
        nonmutating set { editorState.includeTilt = newValue }
    }

    private var draft: ControllerDocument? {
        get { editorState.draft }
        nonmutating set { editorState.draft = newValue }
    }

    private var selectedControlID: String? {
        get { editorState.selectedControlID }
        nonmutating set { editorState.selectedControlID = newValue }
    }

    private var isWorkspaceExpanded: Bool {
        draft != nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Universal Controller")
                            .font(.title2.weight(.semibold))
                        Text("Design a controller for the app you're using")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, isWorkspaceExpanded ? 0 : 30)

                    if isWorkspaceExpanded {
                        HStack {
                            Button {
                                withAnimation(.smooth(duration: 0.3)) {
                                    showingSettings.toggle()
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 30, height: 24)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("App and generation settings")

                            pairingToolbarControl
                            Spacer()
                        }
                        .overlay(alignment: .topLeading) {
                            if showingSettings {
                                settingsPopover
                                    .offset(y: 32)
                                    .transition(.opacity.combined(
                                        with: .scale(scale: 0.98, anchor: .topLeading)
                                    ))
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                    }

                    if isWorkspaceExpanded {
                        VStack(alignment: .leading, spacing: 18) {
                            generationSection

                            toolTabs
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                            if pairingHost.state != .idle {
                                pairingSection
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                if showingSettings {
                                    settingsContent
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                generationSection

                                if pairingHost.state != .idle {
                                    pairingSection
                                }

                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: isWorkspaceExpanded ? 340 : nil)
                .frame(maxWidth: isWorkspaceExpanded ? nil : .infinity)
                .frame(maxHeight: .infinity, alignment: .top)

                if isWorkspaceExpanded {
                    Divider()
                        .transition(.opacity)

                    previewWorkspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(24)
        .frame(width: isWorkspaceExpanded ? 1100 : 430, height: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            showingSettings = !isWorkspaceExpanded
        }
        .onChange(of: isWorkspaceExpanded) { _, expanded in
            withAnimation(.smooth(duration: 0.55)) {
                showingSettings = false
                selectedToolTab = .controls
            }
            onWorkspaceExpansionChanged(expanded)
        }
        .animation(.smooth(duration: 0.55), value: isWorkspaceExpanded)
        .task {
            while !Task.isCancelled {
                permissionStatus = MacActionExecutor.permissionStatus
                if permissionStatus.canControl { showKeyboardHelp = false }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT APP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let icon = context?.application.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "macwindow")
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context?.displayName ?? "No app captured")
                            .fontWeight(.medium)
                        Text(context?.windowTitle ?? (context?.canReadWindowTitle == false
                            ? "Allow Accessibility access to read window titles"
                            : "Window title unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: permissionStatus.canControl
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill")
                        .foregroundStyle(permissionStatus.canControl ? .green : .orange)
                    Text(permissionStatus.canControl
                        ? "Accessibility and keyboard control ready"
                        : permissionStatus.accessibility
                            ? "Keyboard event access required"
                            : "Accessibility access required")
                        .font(.subheadline)
                    Spacer()
                }

                if !permissionStatus.canControl {
                    Button(permissionStatus.accessibility
                        ? "Request Keyboard Access"
                        : "Grant Accessibility") {
                        onRequestPermission()
                        permissionStatus = MacActionExecutor.permissionStatus
                        showKeyboardHelp = permissionStatus.accessibility &&
                            !permissionStatus.keyboardControl
                    }
                }

                if showKeyboardHelp {
                    Text("If macOS shows no prompt, its keyboard event permission may need a reset. See README for the command.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let context, MacActionExecutor.isKeynote(context.application) {
                    HStack {
                        Button("Test Next Slide") { onNextSlide() }
                            .disabled(!permissionStatus.canControl)
                        Text("Sends Right Arrow to Keynote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("OPENAI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if editorState.hasAPIKey {
                    HStack {
                        Label("API key saved in Keychain", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove Key") {
                            onRemoveAPIKey()
                            apiKeyEntry = ""
                        }
                        .font(.caption)
                    }
                } else {
                    HStack {
                        SecureField("OpenAI API key", text: $apiKeyEntry)
                            .textFieldStyle(.roundedBorder)
                        Button("Save Key") {
                            apiKeyError = onSaveAPIKey(apiKeyEntry)
                            if apiKeyError == nil { apiKeyEntry = "" }
                        }
                        .disabled(apiKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                        Text("Stored only in macOS Keychain.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(
                            "Create an API key",
                            destination: URL(string: "https://platform.openai.com/api-keys")!
                        )
                    }
                    .font(.caption)
                }

                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var settingsPopover: some View {
        settingsContent
        .padding(18)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary)
        )
        .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
    }

    @ViewBuilder
    private var pairingToolbarControl: some View {
        switch pairingHost.state {
        case .idle, .failed:
            Button("Pair iPhone") {
                startPairing()
            }
            .buttonStyle(SolidGreyButtonStyle())
            .disabled(draftValidationError != nil || editorState.isGenerating)
        case .starting, .waiting, .authenticating:
            Label("Pairing iPhone", systemImage: "iphone.radiowaves.left.and.right")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .connected:
            Label("iPhone connected", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }

    private func startPairing() {
        if let draft, draftValidationError == nil {
            onStartPairing(draft)
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IPHONE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch pairingHost.state {
            case .idle:
                EmptyView()

            case .starting:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Starting a secure local pairing session…")
                    Spacer()
                    Button("Cancel") { pairingHost.stopSession() }
                }
                .padding(14)

            case .waiting, .authenticating:
                HStack(alignment: .top, spacing: 20) {
                    if let payload = pairingHost.descriptor?.qrPayload {
                        PairingQRCodeView(payload: payload)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if case .authenticating(let deviceName) = pairingHost.state {
                            Label("Authenticating \(deviceName)…", systemImage: "lock.shield")
                                .font(.headline)
                        } else {
                            Text("Scan with Universal Controller")
                                .font(.headline)
                            Text("Open the iPhone app, tap Scan Mac QR, and point it at this code.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let expiresAt = pairingHost.descriptor?.expiresAt {
                            Text("Expires \(expiresAt, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel pairing") { pairingHost.stopSession() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .connected(let deviceName):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected to \(deviceName)")
                            .font(.headline)
                        Text(pairingHost.lastPingAt == nil
                            ? "Waiting for connection test…"
                            : "Bidirectional connection verified")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let controller = pairingHost.controller {
                            Text("\(controller.name) is ready on your iPhone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Pair from Keynote to send the demo button")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect") { pairingHost.stopSession() }
                }
                .padding(14)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            case .failed(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline)
                    Spacer()
                }
                .padding(14)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private extension MacOverlayView {
    var generationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YOUR CONTROLLER")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(
                generationPlaceholder,
                text: $editorState.prompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...4)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .disabled(!canEditDraft)
            .onKeyPress(.return) {
                guard canGenerate else { return .ignored }
                submitGeneration()
                return .handled
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer()
                if editorState.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: submitGeneration) {
                    Label(
                        editorState.isIterativePrompt ? "Update Controller" : "Generate Controller",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(SolidGreyButtonStyle())
                .disabled(!canGenerate)
            }

            if let message = editorState.generationError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    var generationPlaceholder: String {
        editorState.isIterativePrompt
            ? "Try “Add another button” or “Make Next larger”"
            : "For example: Next, Previous, and Blackout buttons"
    }

    var canGenerate: Bool {
        canEditDraft &&
        editorState.hasAPIKey &&
        !editorState.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        context?.application.bundleIdentifier != nil
    }

    func submitGeneration() {
        guard canGenerate else { return }
        onGenerate(editorState.prompt)
    }

    var canEditDraft: Bool {
        guard !editorState.isGenerating else { return false }
        return switch pairingHost.state {
        case .idle, .failed: true
        case .starting, .waiting, .authenticating, .connected: false
        }
    }

    var canEditLayout: Bool {
        !editorState.isGenerating && draft != nil
    }

    var draftValidationError: String? {
        guard let draft else { return "Generate a controller before pairing." }
        do {
            try SchemaValidator.validate(draft)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func makeDraft() {
        guard canEditDraft else { return }
        draft = onMakeDraft(demoStyle, includeTilt)
        selectedControlID = draft?.layout.items.first?.controlID
        editorState.draftWasGenerated = false
        editorState.isIterativePrompt = false
        editorState.layoutDirty = false
        editorState.generationError = nil
    }

    func replaceDraft(
        name: String? = nil,
        preferredOrientation: ControllerOrientation? = nil,
        layout: ControllerLayout? = nil,
        controls: [ControlDefinition]? = nil,
        bindings: [ControlBinding]? = nil
    ) {
        guard let draft else { return }
        let layouts = layout.map {
            draft.layouts.replacing($0, for: preferredOrientation ?? draft.preferredOrientation)
        } ?? draft.layouts
        self.draft = ControllerDocument(
            schemaVersion: draft.schemaVersion,
            id: draft.id,
            revision: draft.revision,
            name: name ?? draft.name,
            target: draft.target,
            preferredOrientation: preferredOrientation ?? draft.preferredOrientation,
            layouts: layouts,
            controls: controls ?? draft.controls,
            bindings: bindings ?? draft.bindings
        )
        editorState.layoutDirty = true
    }

    func updateFrame(_ id: String, _ frame: LayoutRect) {
        guard let draft, canEditLayout else { return }
        let obstacles = draft.layout.items
            .filter { $0.controlID != id }
            .map(\.frame)
        let previous = draft.layout.items.first { $0.controlID == id }?.frame ?? frame
        let resolved = LayoutEditing.resolvedOrPrevious(
            frame,
            previous: previous,
            avoiding: obstacles
        )
        let items = draft.layout.items.map { item in
            item.controlID == id
                ? ControllerLayoutItem(controlID: id, frame: resolved)
                : item
        }
        replaceDraft(layout: ControllerLayout(items: items))
    }

    func applyLayout() {
        guard let draft, canEditLayout else { return }
        let committed = ControllerDocument(
            schemaVersion: draft.schemaVersion,
            id: draft.id,
            revision: draft.revision + 1,
            name: draft.name,
            target: draft.target,
            preferredOrientation: draft.preferredOrientation,
            layouts: draft.layouts,
            controls: draft.controls,
            bindings: draft.bindings
        )
        if let error = onApplyLayout(committed) {
            editorState.generationError = error
            return
        }
        self.draft = committed
        editorState.layoutDirty = false
        editorState.generationError = nil
    }

    var assetLibraryPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Drag-and-drop controls")
                .font(.headline)
            Text("Buttons, sliders, joysticks, and more will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    .secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        }
    }

    var toolTabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(EditorToolTab.allCases) { tab in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            selectedToolTab = tab
                        }
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .font(.subheadline.weight(
                                selectedToolTab == tab ? .semibold : .regular
                            ))
                            .foregroundStyle(selectedToolTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedToolTab == tab
                            ? Color.primary.opacity(0.13)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
            .padding(3)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))

            switch selectedToolTab {
            case .controls:
                if let draft {
                    VStack(alignment: .leading, spacing: 12) {
                        inspector(draft)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .disabled(!canEditLayout)

                        if let draftValidationError {
                            Label(draftValidationError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                }
            case .assets:
                ScrollView {
                    assetLibraryPlaceholder
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.22), value: selectedToolTab)
    }

    var previewWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PREVIEW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 20)

            HStack {
                Spacer()
                if let draft {
                    controllerPreview(draft)
                        .frame(
                            width: draft.preferredOrientation == .portrait ? 320 : 600,
                            height: draft.preferredOrientation == .portrait ? 430 : 350
                        )
                        .disabled(!canEditLayout)
                } else {
                    EmptyPhonePreview()
                        .frame(width: 600, height: 350)
                }
                Spacer()
            }

            Spacer(minLength: 20)

            HStack {
                if let draft {
                    orientationPicker(for: draft)
                }
                Spacer()
                if editorState.layoutDirty {
                    Button("Apply Layout") {
                        applyLayout()
                    }
                    .buttonStyle(SolidGreyButtonStyle())
                    .disabled(!canEditLayout)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    func orientationPicker(for draft: ControllerDocument) -> some View {
        Picker("Phone orientation", selection: Binding(
            get: { draft.preferredOrientation },
            set: { replaceDraft(preferredOrientation: $0) }
        )) {
            ForEach(ControllerOrientation.allCases, id: \.self) { orientation in
                Text(orientation.displayName).tag(orientation)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 180)
        .tint(.gray)
    }

    func controllerPreview(_ draft: ControllerDocument) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ForEach(draft.layout.items) { item in
                    if let control = draft.control(id: item.controlID) {
                        EditablePreviewControl(
                            control: control,
                            frame: item.frame,
                            canvasSize: size,
                            obstacles: draft.layout.items
                                .filter { $0.controlID != control.id }
                                .map(\.frame),
                            isSelected: selectedControlID == control.id,
                            color: previewColor(for: control),
                            onSelect: { selectedControlID = control.id },
                            onChangeFrame: { frame in
                                updateFrame(control.id, frame)
                            }
                        )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "previewCanvas")
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { selectedControlID = nil }
        }
        .padding(14)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
    }

    func previewColor(for control: ControlDefinition) -> Color {
        switch control.kind {
        case .button(let configuration):
            switch configuration.face {
            case .a: .green
            case .b: .red
            case .x: .blue
            case .y: .orange
            case .standard:
                switch configuration.variant {
                case .primary: .indigo
                case .secondary: .gray
                case .destructive: .red
                }
            }
        case .joystick: .blue
        case .motion: .teal
        }
    }

    func inspector(_ draft: ControllerDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = selectedControlID,
                   let control = draft.control(id: id),
                   let index = draft.layout.items.firstIndex(where: { $0.controlID == id }) {
                    Text(control.kind.capabilityID.rawValue.capitalized)
                        .font(.headline)

                    TextField("Label", text: Binding(
                        get: { self.draft?.control(id: id)?.label ?? "" },
                        set: { label in
                            updateControl(id) { ControlDefinition(id: $0.id, label: label, kind: $0.kind) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    let frame = draft.layout.items[index].frame
                    Text("Position \(Int(frame.x * 100))%, \(Int(frame.y * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Size \(Int(frame.width * 100))% × \(Int(frame.height * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .button(let configuration) = control.kind {
                        Picker("Face", selection: Binding(
                            get: { currentButtonConfiguration(id)?.face ?? .standard },
                            set: { face in
                                updateControl(id) { control in
                                    ControlDefinition(id: control.id, label: control.label, kind: .button(
                                        ButtonControlConfiguration(
                                            variant: configuration.variant,
                                            hapticsEnabled: configuration.hapticsEnabled,
                                            face: face
                                        )
                                    ))
                                }
                            }
                        )) {
                            ForEach(ButtonFace.allCases, id: \.self) { face in
                                Text(face == .standard ? "Standard" : face.rawValue.uppercased()).tag(face)
                            }
                        }
                        if configuration.face == .standard {
                            Picker("Style", selection: Binding(
                                get: { currentButtonConfiguration(id)?.variant ?? .primary },
                                set: { variant in
                                    updateControl(id) { control in
                                        ControlDefinition(id: control.id, label: control.label, kind: .button(
                                            ButtonControlConfiguration(
                                                variant: variant,
                                                hapticsEnabled: configuration.hapticsEnabled,
                                                face: configuration.face
                                            )
                                        ))
                                    }
                                }
                            )) {
                                Text("Primary").tag(ButtonVariant.primary)
                                Text("Secondary").tag(ButtonVariant.secondary)
                                Text("Destructive").tag(ButtonVariant.destructive)
                            }
                        }
                    }

                    Divider()
                    Text("ACTION")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    actionInspector(id)
                } else {
                    Text("Select a control in the preview")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func actionInspector(_ id: String) -> some View {
        if let action = draft?.bindings.first(where: { $0.controlID == id })?.action {
            switch action {
            case .keyChord:
                Picker("Key", selection: Binding(
                    get: { currentKey(id) },
                    set: { key in setAction(id, .keyChord(KeyChordAction(key: key, modifiers: currentModifiers(id)))) }
                )) {
                    ForEach(SemanticKey.allCases, id: \.self) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                ForEach(KeyModifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.rawValue.capitalized, isOn: Binding(
                        get: { currentModifiers(id).contains(modifier) },
                        set: { enabled in
                            var modifiers = currentModifiers(id).filter { $0 != modifier }
                            if enabled { modifiers.append(modifier) }
                            setAction(id, .keyChord(KeyChordAction(key: currentKey(id), modifiers: modifiers)))
                        }
                    ))
                }
            case .mouseMove:
                Text("Move the Mac pointer")
                    .font(.subheadline)
                Stepper("Gain: \(Int(currentMouseMove(id).gain))", value: Binding(
                    get: { currentMouseMove(id).gain },
                    set: { setAction(id, .mouseMove(MouseMoveAction(gain: $0, deadZone: currentMouseMove(id).deadZone))) }
                ), in: 1...40, step: 1)
                VStack(alignment: .leading) {
                    Text("Dead zone: \(currentMouseMove(id).deadZone, specifier: "%.2f")")
                    Slider(value: Binding(
                        get: { currentMouseMove(id).deadZone },
                        set: { setAction(id, .mouseMove(MouseMoveAction(gain: currentMouseMove(id).gain, deadZone: $0))) }
                    ), in: 0...0.5)
                }
            }
        }
    }

    func updateControl(_ id: String, transform: (ControlDefinition) -> ControlDefinition) {
        guard let draft, canEditLayout else { return }
        replaceDraft(controls: draft.controls.map { $0.id == id ? transform($0) : $0 })
    }

    func currentButtonConfiguration(_ id: String) -> ButtonControlConfiguration? {
        guard let control = draft?.control(id: id), case .button(let configuration) = control.kind else {
            return nil
        }
        return configuration
    }

    func setAction(_ id: String, _ action: ActionDefinition) {
        guard let draft, canEditLayout else { return }
        replaceDraft(bindings: draft.bindings.map { binding in
            binding.controlID == id
                ? ControlBinding(id: binding.id, controlID: id, event: binding.event, action: action)
                : binding
        })
    }

    func currentKey(_ id: String) -> SemanticKey {
        guard let binding = draft?.bindings.first(where: { $0.controlID == id }),
              case .keyChord(let action) = binding.action else { return .rightArrow }
        return action.key
    }

    func currentModifiers(_ id: String) -> [KeyModifier] {
        guard let binding = draft?.bindings.first(where: { $0.controlID == id }),
              case .keyChord(let action) = binding.action else { return [] }
        return action.modifiers
    }

    func currentMouseMove(_ id: String) -> MouseMoveAction {
        guard let binding = draft?.bindings.first(where: { $0.controlID == id }),
              case .mouseMove(let action) = binding.action else {
            return MouseMoveAction(gain: 10, deadZone: 0.1)
        }
        return action
    }

}

private struct SolidGreyButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(
                        isEnabled
                            ? (configuration.isPressed ? 0.28 : 0.22)
                            : 0.10
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08))
            )
    }
}

private struct EmptyPhonePreview: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.black.opacity(0.92))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.10))
            }
        .accessibilityLabel("Controller preview waiting for generation")
    }
}

private enum ResizeHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var movesLeft: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: true
        default: false
        }
    }

    var movesRight: Bool {
        switch self {
        case .topRight, .right, .bottomRight: true
        default: false
        }
    }

    var movesTop: Bool {
        switch self {
        case .topLeft, .top, .topRight: true
        default: false
        }
    }

    var movesBottom: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: true
        default: false
        }
    }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        default: false
        }
    }
}

private enum LayoutEditing {
    static let gap = 0.012
    static let minimumSize = 0.08

    static func overlaps(_ a: LayoutRect, _ b: LayoutRect, gap: Double = gap) -> Bool {
        a.x < b.maxX + gap &&
        a.maxX + gap > b.x &&
        a.y < b.maxY + gap &&
        a.maxY + gap > b.y
    }

    static func pixelRect(for frame: LayoutRect, in canvasSize: CGSize) -> CGRect {
        let clamped = frame.clamped(minimumSize: minimumSize)
        return CGRect(
            x: clamped.x * canvasSize.width,
            y: clamped.y * canvasSize.height,
            width: clamped.width * canvasSize.width,
            height: clamped.height * canvasSize.height
        )
    }

    static func hitTestHandle(localPoint: CGPoint, size: CGSize) -> ResizeHandle? {
        // Keep a real move target in the middle — edge band scales with control size.
        let inset = min(10, max(5, min(size.width, size.height) * 0.18))
        guard size.width > inset * 2.5, size.height > inset * 2.5 else {
            // Tiny controls: corners only, so the center stays draggable.
            let corner = inset * 1.2
            let nearLeft = localPoint.x <= corner
            let nearRight = localPoint.x >= size.width - corner
            let nearTop = localPoint.y <= corner
            let nearBottom = localPoint.y >= size.height - corner
            switch (nearTop, nearBottom, nearLeft, nearRight) {
            case (true, false, true, false): return .topLeft
            case (true, false, false, true): return .topRight
            case (false, true, true, false): return .bottomLeft
            case (false, true, false, true): return .bottomRight
            default: return nil
            }
        }

        let nearLeft = localPoint.x <= inset
        let nearRight = localPoint.x >= size.width - inset
        let nearTop = localPoint.y <= inset
        let nearBottom = localPoint.y >= size.height - inset

        switch (nearTop, nearBottom, nearLeft, nearRight) {
        case (true, false, true, false): return .topLeft
        case (true, false, false, true): return .topRight
        case (false, true, true, false): return .bottomLeft
        case (false, true, false, true): return .bottomRight
        case (true, false, false, false): return .top
        case (false, true, false, false): return .bottom
        case (false, false, true, false): return .left
        case (false, false, false, true): return .right
        default: return nil
        }
    }

    static func resized(
        from origin: LayoutRect,
        handle: ResizeHandle,
        dx: Double,
        dy: Double
    ) -> LayoutRect {
        var x = origin.x
        var y = origin.y
        var width = origin.width
        var height = origin.height

        if handle.movesLeft {
            x = origin.x + dx
            width = origin.width - dx
        } else if handle.movesRight {
            width = origin.width + dx
        }

        if handle.movesTop {
            y = origin.y + dy
            height = origin.height - dy
        } else if handle.movesBottom {
            height = origin.height + dy
        }

        if width < minimumSize {
            if handle.movesLeft {
                x = origin.maxX - minimumSize
            }
            width = minimumSize
        }
        if height < minimumSize {
            if handle.movesTop {
                y = origin.maxY - minimumSize
            }
            height = minimumSize
        }

        if x < 0 {
            if handle.movesLeft { width += x }
            x = 0
        }
        if y < 0 {
            if handle.movesTop { height += y }
            y = 0
        }
        if x + width > 1 {
            if handle.movesRight {
                width = 1 - x
            } else if handle.movesLeft {
                x = 1 - width
            } else {
                width = 1 - x
            }
        }
        if y + height > 1 {
            if handle.movesBottom {
                height = 1 - y
            } else if handle.movesTop {
                y = 1 - height
            } else {
                height = 1 - y
            }
        }

        return LayoutRect(
            x: x,
            y: y,
            width: max(minimumSize, min(1, width)),
            height: max(minimumSize, min(1, height))
        ).clamped(minimumSize: minimumSize)
    }

    /// Keeps `proposed` when clear; otherwise slides on one axis or stays put.
    /// If already overlapping, allow free movement (still canvas-clamped) so controls can untangle.
    static func resolvedOrPrevious(
        _ proposed: LayoutRect,
        previous: LayoutRect,
        avoiding obstacles: [LayoutRect]
    ) -> LayoutRect {
        let clamped = proposed.clamped(minimumSize: minimumSize)
        let previousOverlapping = obstacles.contains { overlaps(previous, $0) }
        if previousOverlapping {
            return clamped
        }
        if !obstacles.contains(where: { overlaps(clamped, $0) }) {
            return clamped
        }

        let xOnly = LayoutRect(
            x: proposed.x,
            y: previous.y,
            width: proposed.width,
            height: previous.height
        ).clamped(minimumSize: minimumSize)
        if !obstacles.contains(where: { overlaps(xOnly, $0) }) {
            return xOnly
        }

        let yOnly = LayoutRect(
            x: previous.x,
            y: proposed.y,
            width: previous.width,
            height: proposed.height
        ).clamped(minimumSize: minimumSize)
        if !obstacles.contains(where: { overlaps(yOnly, $0) }) {
            return yOnly
        }

        return previous.clamped(minimumSize: minimumSize)
    }
}

private struct EditablePreviewControl: View {
    let control: ControlDefinition
    let frame: LayoutRect
    let canvasSize: CGSize
    let obstacles: [LayoutRect]
    let isSelected: Bool
    let color: Color
    let onSelect: () -> Void
    let onChangeFrame: (LayoutRect) -> Void

    @State private var liveFrame: LayoutRect?
    @State private var gestureOrigin: LayoutRect?
    @State private var activeHandle: ResizeHandle?

    private var displayed: LayoutRect {
        (liveFrame ?? frame).clamped(minimumSize: LayoutEditing.minimumSize)
    }

    private var pixelFrame: CGRect {
        LayoutEditing.pixelRect(for: displayed, in: canvasSize)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(isSelected ? 0.95 : 0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            .white.opacity(isSelected ? 0.95 : 0.25),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .shadow(color: .black.opacity(0.25), radius: isSelected ? 8 : 3, y: 2)

            Text(control.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(10)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .allowsHitTesting(false)

            if isSelected {
                ForEach(ResizeHandle.allCases, id: \.self) { handle in
                    handleView(handle)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: max(1, pixelFrame.width), height: max(1, pixelFrame.height))
        .contentShape(Rectangle())
        // `position` keeps hit-testing aligned with the drawn control (unlike `offset`).
        .position(x: pixelFrame.midX, y: pixelFrame.midY)
        .zIndex(isSelected ? 10 : 0)
        .gesture(canvasDragGesture)
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private func handleView(_ handle: ResizeHandle) -> some View {
        let size: CGFloat = handle.isCorner ? 11 : 7
        Circle()
            .fill(.white)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(.black.opacity(0.22), lineWidth: 1)
            }
            .position(handlePosition(handle))
    }

    private func handlePosition(_ handle: ResizeHandle) -> CGPoint {
        let width = max(1, pixelFrame.width)
        let height = max(1, pixelFrame.height)
        switch handle {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: width / 2, y: 0)
        case .topRight: return CGPoint(x: width, y: 0)
        case .left: return CGPoint(x: 0, y: height / 2)
        case .right: return CGPoint(x: width, y: height / 2)
        case .bottomLeft: return CGPoint(x: 0, y: height)
        case .bottom: return CGPoint(x: width / 2, y: height)
        case .bottomRight: return CGPoint(x: width, y: height)
        }
    }

    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("previewCanvas"))
            .onChanged { value in
                if gestureOrigin == nil {
                    onSelect()
                    let origin = frame.clamped(minimumSize: LayoutEditing.minimumSize)
                    gestureOrigin = origin
                    liveFrame = origin
                    let startRect = LayoutEditing.pixelRect(for: origin, in: canvasSize)
                    let local = CGPoint(
                        x: value.startLocation.x - startRect.minX,
                        y: value.startLocation.y - startRect.minY
                    )
                    activeHandle = LayoutEditing.hitTestHandle(
                        localPoint: local,
                        size: startRect.size
                    )
                }

                guard let origin = gestureOrigin,
                      canvasSize.width > 0,
                      canvasSize.height > 0 else { return }

                let dx = (value.location.x - value.startLocation.x) / canvasSize.width
                let dy = (value.location.y - value.startLocation.y) / canvasSize.height

                let proposed: LayoutRect
                if let handle = activeHandle {
                    proposed = LayoutEditing.resized(from: origin, handle: handle, dx: dx, dy: dy)
                } else {
                    proposed = LayoutRect(
                        x: origin.x + dx,
                        y: origin.y + dy,
                        width: origin.width,
                        height: origin.height
                    )
                }

                let next = LayoutEditing.resolvedOrPrevious(
                    proposed,
                    previous: liveFrame ?? origin,
                    avoiding: obstacles
                )
                if liveFrame != next {
                    liveFrame = next
                    onChangeFrame(next)
                }
            }
            .onEnded { _ in
                if let liveFrame {
                    onChangeFrame(liveFrame)
                }
                gestureOrigin = nil
                liveFrame = nil
                activeHandle = nil
            }
    }
}
