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

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("esc to close")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
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
            draft.layouts.replacing($0, for: draft.preferredOrientation)
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
                            .disabled(!canEditDraft)

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
                        .disabled(!canEditDraft)
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
            let rows = previewRows(for: draft)
            let spacing: CGFloat = 8
            let units = rows.reduce(0) { $0 + $1.heightUnits }
            let available = max(0, geometry.size.height - CGFloat(max(rows.count - 1, 0)) * spacing)
            let contentHeight = max(available, CGFloat(units) * 54)

            ScrollView {
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(rows) { row in
                        GridRow {
                            ForEach(row.items) { item in
                                if let control = draft.control(id: item.controlID) {
                                    previewCell(control)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .gridCellColumns(item.columnSpan)
                                }
                            }
                        }
                        .frame(height: contentHeight * CGFloat(row.heightUnits) / CGFloat(max(units, 1)))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
    }

    func previewCell(_ control: ControlDefinition) -> some View {
        Button {
            selectedControlID = control.id
        } label: {
            VStack(spacing: 5) {
                switch control.kind {
                case .button(let configuration):
                    if configuration.face != .standard {
                        Text(configuration.face.rawValue.uppercased())
                            .font(.title3.bold())
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(previewColor(for: control)))
                    } else {
                        Image(systemName: "hand.tap.fill")
                            .font(.title2)
                    }
                case .joystick:
                    Image(systemName: "circle.circle.fill")
                        .font(.system(size: 44))
                case .motion:
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.title2)
                }
                Text(control.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(
                previewColor(for: control).opacity(selectedControlID == control.id ? 0.65 : 0.25),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selectedControlID == control.id ? .white : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(control.label)")
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

                    HStack {
                        Button("Move earlier", systemImage: "arrow.up") { moveControl(id, by: -1) }
                            .disabled(index == 0)
                        Button("Move later", systemImage: "arrow.down") { moveControl(id, by: 1) }
                            .disabled(index == draft.layout.items.count - 1)
                    }
                    .labelStyle(.iconOnly)
                    .help("Change the control's position in the phone layout")

                    Stepper("Width: \(draft.layout.items[index].columnSpan) column(s)", value: Binding(
                        get: { self.draft?.layout.items.first(where: { $0.controlID == id })?.columnSpan ?? 1 },
                        set: { updateSize(id, columns: $0) }
                    ), in: 1...draft.layout.columns)

                    Stepper("Height: \(draft.layout.items[index].rowSpan) unit(s)", value: Binding(
                        get: { self.draft?.layout.items.first(where: { $0.controlID == id })?.rowSpan ?? 1 },
                        set: { updateSize(id, rows: $0) }
                    ), in: 1...SchemaValidator.maximumSpan)

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

    func previewRows(for document: ControllerDocument) -> [PreviewRow] {
        var rows: [[ControllerLayoutItem]] = []
        var current: [ControllerLayoutItem] = []
        var occupied = 0
        for item in document.layout.items {
            if occupied + item.columnSpan > document.layout.columns {
                rows.append(current)
                current = []
                occupied = 0
            }
            current.append(item)
            occupied += item.columnSpan
            if occupied == document.layout.columns {
                rows.append(current)
                current = []
                occupied = 0
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows.enumerated().map { PreviewRow(id: $0.offset, items: $0.element) }
    }

    func moveControl(_ id: String, by offset: Int) {
        guard let draft,
              let index = draft.layout.items.firstIndex(where: { $0.controlID == id }),
              draft.layout.items.indices.contains(index + offset) else { return }
        var items = draft.layout.items
        items.swapAt(index, index + offset)
        replaceDraft(layout: ControllerLayout(columns: draft.layout.columns, items: items))
    }

    func updateSize(_ id: String, columns: Int? = nil, rows: Int? = nil) {
        guard let draft else { return }
        let items = draft.layout.items.map { item in
            item.controlID == id
                ? ControllerLayoutItem(
                    controlID: id,
                    columnSpan: columns ?? item.columnSpan,
                    rowSpan: rows ?? item.rowSpan
                )
                : item
        }
        replaceDraft(layout: ControllerLayout(columns: draft.layout.columns, items: items))
    }

    func updateControl(_ id: String, transform: (ControlDefinition) -> ControlDefinition) {
        guard let draft else { return }
        replaceDraft(controls: draft.controls.map { $0.id == id ? transform($0) : $0 })
    }

    func currentButtonConfiguration(_ id: String) -> ButtonControlConfiguration? {
        guard let control = draft?.control(id: id), case .button(let configuration) = control.kind else {
            return nil
        }
        return configuration
    }

    func setAction(_ id: String, _ action: ActionDefinition) {
        guard let draft else { return }
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

private struct PreviewRow: Identifiable {
    let id: Int
    let items: [ControllerLayoutItem]

    var heightUnits: Int {
        max(items.map(\.rowSpan).max() ?? 1, 1)
    }
}
