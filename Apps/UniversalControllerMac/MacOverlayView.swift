import AppKit
import SwiftUI

enum DemoControllerStyle: String, CaseIterable, Identifiable {
    case presenter = "Presenter"
    case gamepad = "Gamepad"

    var id: Self { self }
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

    @State private var permissionStatus = MacActionExecutor.permissionStatus
    @State private var showKeyboardHelp = false
    @State private var apiKeyEntry = ""
    @State private var apiKeyError: String?

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Universal Controller")
                            .font(.title2.weight(.semibold))
                        Text("Design a controller for the app you're using")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

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
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    Image(systemName: permissionStatus.canControl ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permissionStatus.canControl ? .green : .orange)
                    Text(permissionStatus.canControl ? "Accessibility and keyboard control ready"
                        : permissionStatus.accessibility ? "Keyboard event access required" : "Accessibility access required")
                        .font(.subheadline)
                    Spacer()
                    if !permissionStatus.canControl {
                        Button(permissionStatus.accessibility ? "Request Keyboard Access" : "Grant Accessibility") {
                            onRequestPermission()
                            permissionStatus = MacActionExecutor.permissionStatus
                            showKeyboardHelp = permissionStatus.accessibility && !permissionStatus.keyboardControl
                        }
                    }
                }

                if showKeyboardHelp {
                    Text("If macOS shows no prompt, its keyboard event permission may need a reset. See README for the command.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    if let context, MacActionExecutor.isKeynote(context.application) {
                        Button("Next Slide") { onNextSlide() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!permissionStatus.canControl)
                        Text("Sends Right Arrow to Keynote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Open Keynote to try the local Next Slide action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                generationSection

                if let context, MacActionExecutor.isKeynote(context.application) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STARTING LAYOUT")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if editorState.draftWasGenerated {
                            Button("Use Demo Layout Instead") { makeDraft() }
                                .disabled(!canEditDraft)
                        }
                        HStack(spacing: 16) {
                            Picker("Demo layout", selection: Binding(
                                get: { demoStyle }, set: { demoStyle = $0 }
                            )) {
                                ForEach(DemoControllerStyle.allCases) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(!canEditDraft)
                            Toggle("Phone tilt moves pointer", isOn: Binding(
                                get: { includeTilt }, set: { includeTilt = $0 }
                            ))
                                .disabled(demoStyle != .gamepad || !canEditDraft)
                        }
                    }
                }

                if draft != nil {
                    controllerEditor
                }

                pairingSection

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text(editorState.draftWasGenerated
                        ? "AI draft ready for review. Pair when the controls look right."
                        : "Edit a demo controller or generate one from a request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("esc to close")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
        .frame(width: 700, height: 730)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            if draft?.target.bundleIdentifier != context?.application.bundleIdentifier {
                makeDraft()
            }
        }
        .onChange(of: demoStyle) { _, _ in makeDraft() }
        .onChange(of: includeTilt) { _, _ in makeDraft() }
        .task {
            while !Task.isCancelled {
                permissionStatus = MacActionExecutor.permissionStatus
                if permissionStatus.canControl { showKeyboardHelp = false }
                try? await Task.sleep(for: .seconds(1))
            }
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
                HStack {
                    Label("No iPhone paired", systemImage: "iphone")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pair iPhone") {
                        if let draft, draftValidationError == nil {
                            onStartPairing(draft)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftValidationError != nil || editorState.isGenerating)
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

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
                    Button("New QR") {
                        if let draft, draftValidationError == nil {
                            onStartPairing(draft)
                        }
                    }
                    .disabled(draftValidationError != nil || editorState.isGenerating)
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
                "For example: Next, Previous, and Blackout buttons",
                text: $editorState.prompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...4)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .disabled(!canEditDraft)

            if editorState.hasAPIKey {
                HStack {
                    Label("OpenAI API key saved in Keychain", systemImage: "key.fill")
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
                    Text("Your key stays in macOS Keychain and is used only for generation requests.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Create an API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                }
                .font(.caption)
            }

            HStack {
                Button {
                    onGenerate(editorState.prompt)
                } label: {
                    if editorState.isGenerating {
                        Label(editorState.generationStatus ?? "Generating…", systemImage: "sparkles")
                    } else {
                        Label("Generate Controller", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !canEditDraft || !editorState.hasAPIKey ||
                    editorState.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    context?.application.bundleIdentifier == nil
                )
                if editorState.isGenerating { ProgressView().controlSize(.small) }
                Spacer()
            }

            Text("Generation captures the selected app window and sends its image, your request, and app details to OpenAI. It never captures the whole screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = apiKeyError ?? editorState.generationError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    var canEditDraft: Bool {
        guard !editorState.isGenerating else { return false }
        return switch pairingHost.state {
        case .idle, .failed: true
        case .starting, .waiting, .authenticating, .connected: false
        }
    }

    var draftValidationError: String? {
        guard let draft else { return "Open Keynote to create a controller." }
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
        editorState.generationError = nil
    }

    func replaceDraft(
        name: String? = nil,
        layout: ControllerLayout? = nil,
        controls: [ControlDefinition]? = nil,
        bindings: [ControlBinding]? = nil
    ) {
        guard let draft else { return }
        self.draft = ControllerDocument(
            schemaVersion: draft.schemaVersion,
            id: draft.id,
            revision: draft.revision,
            name: name ?? draft.name,
            target: draft.target,
            layout: layout ?? draft.layout,
            controls: controls ?? draft.controls,
            bindings: bindings ?? draft.bindings
        )
    }

    var controllerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PREVIEW & EDIT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a control to edit it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let draft {
                HStack(alignment: .top, spacing: 16) {
                    controllerPreview(draft)
                        .frame(width: 260, height: 360)
                    inspector(draft)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .disabled(!canEditDraft)

                Text("ACTION MAPPINGS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(draft.controls) { control in
                        HStack {
                            Text(control.label)
                                .lineLimit(1)
                            Spacer()
                            Text(actionSummary(for: control, in: draft))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }

            if let draftValidationError {
                Label(draftValidationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    func controllerPreview(_ draft: ControllerDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Controller name", text: Binding(
                get: { self.draft?.name ?? "" },
                set: { replaceDraft(name: $0) }
            ))
            .font(.subheadline.weight(.semibold))
            .textFieldStyle(.plain)

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
            .padding(14)
        }
        .frame(height: 360)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
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

    func actionSummary(for control: ControlDefinition, in draft: ControllerDocument) -> String {
        guard let binding = draft.bindings.first(where: { $0.controlID == control.id }) else {
            return "No action"
        }
        switch binding.action {
        case .keyChord(let action):
            let parts = action.modifiers.map { $0.rawValue.capitalized } + [action.key.rawValue]
            return parts.joined(separator: " + ")
        case .mouseMove(let action):
            return "Move pointer · gain \(Int(action.gain))"
        }
    }
}

private struct PreviewRow: Identifiable {
    let id: Int
    let items: [ControllerLayoutItem]

    var heightUnits: Int {
        max(items.map(\.rowSpan).max() ?? 1, 1)
    }
}
