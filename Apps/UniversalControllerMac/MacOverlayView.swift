import AppKit
import SwiftUI

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
    @Published var sessionPack: ControllerSessionPack?
    @Published var selectedSeatIndex = 0
    @Published var selectedControlID: String?
    @Published var prompt = ""
    @Published var hasAPIKey = OpenAIAPIKeyStore.load() != nil
    @Published var isGenerating = false
    @Published var generationStatus: String?
    @Published var generationError: String?
    @Published var isIterativePrompt = false
    @Published var layoutDirty = false
    @Published var capturingShortcutControlID: String?
    @Published var assetDropTargeted = false
    /// How many phone seats to generate. 1 = solo, 2 = local co-op with distinct mappings.
    @Published var playerCount = 1

    var draft: ControllerDocument? {
        get { sessionPack?.controller(at: selectedSeatIndex) }
        set {
            if let newValue {
                if var pack = sessionPack {
                    let index = pack.seat(at: selectedSeatIndex) == nil ? 0 : selectedSeatIndex
                    pack.setController(newValue, at: index)
                    sessionPack = pack
                    selectedSeatIndex = index
                } else {
                    sessionPack = .single(newValue)
                    selectedSeatIndex = 0
                }
            } else {
                sessionPack = nil
                selectedSeatIndex = 0
            }
        }
    }

    func loadGenerated(_ pack: ControllerSessionPack) {
        sessionPack = pack
        playerCount = min(2, max(1, pack.seatCount))
        selectedSeatIndex = 0
        selectedControlID = pack.primaryController.layout.items.first?.controlID
        isIterativePrompt = true
        layoutDirty = false
        generationError = nil
        prompt = ""
    }

    func loadGenerated(_ document: ControllerDocument) {
        loadGenerated(.single(document))
    }
}

struct MacOverlayView: View {
    let context: AppContext?
    let errorMessage: String?
    @ObservedObject var pairingHost: PairingSessionHost
    @ObservedObject var editorState: ControllerEditorState
    let onClose: () -> Void
    let onRequestPermission: () -> Void
    let onGenerate: (String) -> Void
    let onSaveAPIKey: (String) -> String?
    let onRemoveAPIKey: () -> Void
    let onStartPairing: (ControllerSessionPack) -> Void
    let onNextSlide: () -> Void
    let onWorkspaceExpansionChanged: (Bool) -> Void
    let onApplyLayout: (ControllerSessionPack) -> String?

    @State private var permissionStatus = MacActionExecutor.permissionStatus
    @State private var showKeyboardHelp = false
    @State private var apiKeyEntry = ""
    @State private var apiKeyError: String?
    @State private var showingSettings = true
    @State private var selectedToolTab: EditorToolTab = .controls

    private var draft: ControllerDocument? {
        get { editorState.draft }
        nonmutating set { editorState.draft = newValue }
    }

    private var selectedControlID: String? {
        get { editorState.selectedControlID }
        nonmutating set {
            if editorState.capturingShortcutControlID != nil,
               editorState.capturingShortcutControlID != newValue {
                editorState.capturingShortcutControlID = nil
            }
            editorState.selectedControlID = newValue
        }
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
            Button(editorState.sessionPack?.seatCount ?? 0 > 1 ? "Pair iPhones" : "Pair iPhone") {
                startPairing()
            }
            .buttonStyle(SolidGreyButtonStyle())
            .disabled(draftValidationError != nil || editorState.isGenerating)
        case .starting, .advertising, .authenticating:
            Label(
                pairingHost.seatCount > 1
                    ? "Pairing \(pairingHost.filledSeatCount)/\(pairingHost.seatCount)"
                    : "Pairing iPhone",
                systemImage: "iphone.radiowaves.left.and.right"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .full:
            Label(
                pairingHost.peers.count == 1
                    ? "iPhone connected"
                    : "\(pairingHost.peers.count) iPhones connected",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.green)
        }
    }

    private func startPairing() {
        guard let pack = editorState.sessionPack, draftValidationError == nil else { return }
        onStartPairing(pack)
    }

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editorState.sessionPack?.seatCount ?? 0 > 1 ? "IPHONES" : "IPHONE")
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

            case .advertising, .authenticating:
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
                            Text(
                                pairingHost.seatCount > 1
                                    ? "One QR for every player. First phone is Seat 1, next is Seat 2, and so on."
                                    : "Open the iPhone app, tap Scan Mac QR, and point it at this code."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        if pairingHost.seatCount > 1 {
                            Text("Seats filled \(pairingHost.filledSeatCount)/\(pairingHost.seatCount)")
                                .font(.caption.weight(.semibold))
                        }
                        peerList
                        if let expiresAt = pairingHost.descriptor?.expiresAt {
                            Text("Expires \(expiresAt, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel pairing") { pairingHost.stopSession() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .full:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                pairingHost.peers.count == 1
                                    ? "Connected to \(pairingHost.peers.first?.deviceName ?? "iPhone")"
                                    : "\(pairingHost.peers.count) phones connected"
                            )
                            .font(.headline)
                            Text(pairingHost.lastPingAt == nil
                                ? "Waiting for connection test…"
                                : "Bidirectional connection verified")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { pairingHost.stopSession() }
                    }
                    peerList
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

    @ViewBuilder
    private var peerList: some View {
        if !pairingHost.peers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pairingHost.peers) { peer in
                    let seatLabel = editorState.sessionPack?.seat(at: peer.seatIndex)?.label
                        ?? peer.seatLabel
                    Label(
                        "\(seatLabel) · \(peer.deviceName)",
                        systemImage: "iphone"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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

            Picker("Players", selection: $editorState.playerCount) {
                Text("1").tag(1)
                Text("2").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(!canEditDraft)
            .accessibilityLabel("Players")

            Text(
                editorState.playerCount == 2
                    ? "Two phones share one layout. AI maps Player 1 and Player 2 to different keys."
                    : "One phone controller for the Mac app."
            )
            .font(.caption)
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
        if editorState.isIterativePrompt {
            return "Try “Add another button” or “Make Next larger”"
        }
        if editorState.playerCount == 2 {
            return "For example: local co-op movement — P1 WASD, P2 arrows"
        }
        return "For example: Next, Previous, and Blackout buttons"
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
        return !pairingHost.state.isSessionActive
    }

    var canEditLayout: Bool {
        !editorState.isGenerating && draft != nil
    }

    var draftValidationError: String? {
        guard let pack = editorState.sessionPack else {
            return "Generate a controller before pairing."
        }
        do {
            try SchemaValidator.validate(pack)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func replaceDraft(
        name: String? = nil,
        preferredOrientation: ControllerOrientation? = nil,
        layout: ControllerLayout? = nil,
        controls: [ControlDefinition]? = nil,
        bindings: [ControlBinding]? = nil
    ) {
        guard var pack = editorState.sessionPack,
              let draft = pack.controller(at: editorState.selectedSeatIndex) else { return }
        let layouts = layout.map {
            draft.layouts.replacing($0, for: preferredOrientation ?? draft.preferredOrientation)
        }

        let chromeChanged = name != nil
            || preferredOrientation != nil
            || layout != nil
            || controls != nil
        if chromeChanged {
            pack.updateSharedChrome(
                name: name,
                preferredOrientation: preferredOrientation,
                layouts: layouts ?? draft.layouts,
                controls: controls
            )
        }
        if let bindings {
            pack.updateBindings(bindings, at: editorState.selectedSeatIndex)
        }
        guard chromeChanged || bindings != nil else { return }
        editorState.sessionPack = pack
        editorState.layoutDirty = true
    }

    func updateFrame(_ id: String, _ frame: LayoutRect) {
        guard let draft, canEditLayout else { return }
        let movingOccupies = ControllerCapabilityCatalog.current.occupiesLayout(
            draft.control(id: id)?.kind.capabilityID ?? .button
        )
        let obstacles: [LayoutRect]
        if movingOccupies {
            obstacles = draft.layout.items.compactMap { item in
                guard item.controlID != id,
                      let control = draft.control(id: item.controlID),
                      ControllerCapabilityCatalog.current.occupiesLayout(control.kind.capabilityID) else {
                    return nil
                }
                return item.frame
            }
        } else {
            obstacles = []
        }
        let previous = draft.layout.items.first { $0.controlID == id }?.frame ?? frame
        let resolved = movingOccupies
            ? LayoutEditing.resolvedOrPrevious(frame, previous: previous, avoiding: obstacles)
            : frame.clamped()
        let items = draft.layout.items.map { item in
            item.controlID == id
                ? ControllerLayoutItem(controlID: id, frame: resolved)
                : item
        }
        replaceDraft(layout: ControllerLayout(items: items))
    }

    func applyLayout() {
        guard var pack = editorState.sessionPack, canEditLayout,
              let draft = pack.controller(at: editorState.selectedSeatIndex) else { return }
        pack.updateSharedChrome(revision: draft.revision + 1)
        if let error = onApplyLayout(pack) {
            editorState.generationError = error
            return
        }
        editorState.sessionPack = pack
        editorState.layoutDirty = false
        editorState.generationError = nil
    }

    func addPlayerSeat() {
        guard var pack = editorState.sessionPack, canEditLayout else { return }
        do {
            let index = try pack.addSeat(copyingBindingsFrom: editorState.selectedSeatIndex)
            editorState.sessionPack = pack
            editorState.selectedSeatIndex = index
            editorState.layoutDirty = true
        } catch {
            editorState.generationError = error.localizedDescription
        }
    }

    func removeSelectedSeat() {
        guard var pack = editorState.sessionPack, canEditLayout else { return }
        do {
            try pack.removeSeat(at: editorState.selectedSeatIndex)
            editorState.sessionPack = pack
            editorState.selectedSeatIndex = min(
                editorState.selectedSeatIndex,
                max(0, pack.seatCount - 1)
            )
            editorState.layoutDirty = true
        } catch {
            editorState.generationError = error.localizedDescription
        }
    }

    var seatSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEATS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let pack = editorState.sessionPack {
                Picker("Seat", selection: $editorState.selectedSeatIndex) {
                    ForEach(pack.seats) { seat in
                        Text(seat.label).tag(seat.index)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(pack.seatCount < 2)

                Text("Layout is shared. Action mappings below apply to \(pack.seat(at: editorState.selectedSeatIndex)?.label ?? "this seat").")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Add seat") { addPlayerSeat() }
                        .disabled(!canEditLayout || pack.seatCount >= ControllerSessionPack.maximumSeats)
                    if pack.seatCount > 1 {
                        Button("Remove seat", role: .destructive) { removeSelectedSeat() }
                            .disabled(!canEditLayout || pairingHost.state.isSessionActive)
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    var assetLibraryPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag a control onto the preview, or click to add.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft == nil {
                Text("Generate a controller first, then add more pieces here.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118), spacing: 10)],
                spacing: 10
            ) {
                ForEach(ControllerCapabilityCatalog.current.controls, id: \.id) { asset in
                    AssetLibraryTile(
                        asset: asset,
                        isEnabled: canEditLayout
                    ) {
                        addCatalogAsset(asset, dropPoint: nil, canvasSize: .zero)
                    }
                    .draggable(asset.id.rawValue) {
                        AssetLibraryTile(asset: asset, isEnabled: true, onAdd: {})
                            .frame(width: 120)
                            .opacity(0.9)
                    }
                    .opacity(canEditLayout ? 1 : 0.45)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func addCatalogAsset(
        _ asset: ControlCapabilityDescriptor,
        dropPoint: CGPoint?,
        canvasSize: CGSize
    ) {
        guard let draft, canEditLayout else { return }

        let controlID = uniqueControlID(in: draft)
        let control = asset.makeControl(id: controlID)
        let bindings = asset.makeDefaultBindings(controlID: controlID)

        var frame = asset.defaultFrame
        if let dropPoint, canvasSize.width > 0, canvasSize.height > 0 {
            frame = LayoutRect(
                x: (dropPoint.x / canvasSize.width) - asset.defaultWidth / 2,
                y: (dropPoint.y / canvasSize.height) - asset.defaultHeight / 2,
                width: asset.defaultWidth,
                height: asset.defaultHeight
            ).clamped()
        }
        frame = placeFrame(
            frame,
            avoiding: draft.layout.items.compactMap { item in
                guard let control = draft.control(id: item.controlID),
                      ControllerCapabilityCatalog.current.occupiesLayout(control.kind.capabilityID),
                      asset.occupiesLayout else {
                    return nil
                }
                return item.frame
            }
        )

        let portrait = ControllerLayout(
            items: draft.layouts.portrait.items + [
                ControllerLayoutItem(controlID: controlID, frame: frame)
            ]
        )
        let landscape = ControllerLayout(
            items: draft.layouts.landscape.items + [
                ControllerLayoutItem(controlID: controlID, frame: frame)
            ]
        )

        self.draft = ControllerDocument(
            schemaVersion: draft.schemaVersion,
            id: draft.id,
            revision: draft.revision,
            name: draft.name,
            target: draft.target,
            preferredOrientation: draft.preferredOrientation,
            layouts: ControllerLayouts(portrait: portrait, landscape: landscape),
            controls: draft.controls + [control],
            bindings: draft.bindings + bindings
        )
        editorState.layoutDirty = true
        selectedControlID = controlID
        selectedToolTab = .controls
    }

    func uniqueControlID(in draft: ControllerDocument) -> String {
        var index = draft.controls.count + 1
        var candidate = "control-\(index)"
        while draft.control(id: candidate) != nil {
            index += 1
            candidate = "control-\(index)"
        }
        return candidate
    }

    func deleteControl(_ id: String) {
        guard let draft, canEditLayout else { return }
        let portrait = ControllerLayout(
            items: draft.layouts.portrait.items.filter { $0.controlID != id }
        )
        let landscape = ControllerLayout(
            items: draft.layouts.landscape.items.filter { $0.controlID != id }
        )
        self.draft = ControllerDocument(
            schemaVersion: draft.schemaVersion,
            id: draft.id,
            revision: draft.revision,
            name: draft.name,
            target: draft.target,
            preferredOrientation: draft.preferredOrientation,
            layouts: ControllerLayouts(portrait: portrait, landscape: landscape),
            controls: draft.controls.filter { $0.id != id },
            bindings: draft.bindings.filter { $0.controlID != id }
        )
        editorState.layoutDirty = true
        if selectedControlID == id {
            selectedControlID = self.draft?.layout.items.first?.controlID
        }
    }

    func placeFrame(_ preferred: LayoutRect, avoiding obstacles: [LayoutRect]) -> LayoutRect {
        let candidates: [LayoutRect] = [preferred] + stride(from: 0.08, through: 0.72, by: 0.16).flatMap { y in
            stride(from: 0.08, through: 0.72, by: 0.16).map { x in
                LayoutRect(
                    x: x,
                    y: y,
                    width: preferred.width,
                    height: preferred.height
                ).clamped()
            }
        }
        for candidate in candidates {
            let resolved = LayoutEditing.resolvedOrPrevious(
                candidate,
                previous: candidate,
                avoiding: obstacles
            )
            if !obstacles.contains(where: { LayoutEditing.overlaps(resolved, $0) }) {
                return resolved
            }
        }
        return preferred.clamped()
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
                        seatSwitcher
                        Divider()
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
                        let occupiesLayout = ControllerCapabilityCatalog.current.occupiesLayout(
                            control.kind.capabilityID
                        )
                        EditablePreviewControl(
                            control: control,
                            title: previewTitle(for: control),
                            subtitle: previewSubtitle(for: control),
                            systemImage: ControllerCapabilityCatalog.current.control(
                                id: control.kind.capabilityID
                            )?.systemImage,
                            occupiesLayout: occupiesLayout,
                            frame: item.frame,
                            canvasSize: size,
                            obstacles: occupiesLayout
                                ? draft.layout.items.compactMap { other in
                                    guard other.controlID != control.id,
                                          let otherControl = draft.control(id: other.controlID),
                                          ControllerCapabilityCatalog.current.occupiesLayout(
                                              otherControl.kind.capabilityID
                                          ) else {
                                        return nil
                                    }
                                    return other.frame
                                }
                                : [],
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
            .dropDestination(for: String.self) { items, location in
                guard canEditLayout,
                      let raw = items.first,
                      let kind = ControlCapabilityID(rawValue: raw),
                      let asset = ControllerCapabilityCatalog.current.control(id: kind) else {
                    return false
                }
                addCatalogAsset(asset, dropPoint: location, canvasSize: size)
                return true
            } isTargeted: { targeted in
                editorState.assetDropTargeted = targeted
            }
            .overlay {
                if editorState.assetDropTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
    }

    func previewColor(for control: ControlDefinition) -> Color {
        switch control.kind {
        case .button(let configuration):
            Color(hex: configuration.tintHex) ?? .indigo
        case .joystick: .blue
        case .motion: .teal
        case .trackpad: .purple
        }
    }

    static func defaultTintHex(for face: ButtonFace, fallingBack: String) -> String {
        switch face {
        case .standard: fallingBack
        case .a: "34C759"
        case .b: "FF3B30"
        case .x: "007AFF"
        case .y: "FF9500"
        }
    }

    func previewTitle(for control: ControlDefinition) -> String {
        if case .button(let configuration) = control.kind, configuration.face != .standard {
            return configuration.face.rawValue.uppercased()
        }
        return control.label
    }

    func previewSubtitle(for control: ControlDefinition) -> String? {
        if case .button(let configuration) = control.kind, configuration.face != .standard {
            return control.label
        }
        if !ControllerCapabilityCatalog.current.occupiesLayout(control.kind.capabilityID) {
            return control.label
        }
        return nil
    }

    func inspector(_ draft: ControllerDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = selectedControlID,
                   let control = draft.control(id: id),
                   let index = draft.layout.items.firstIndex(where: { $0.controlID == id }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(control.kind.capabilityID.rawValue.capitalized)
                            .font(.headline)
                        Spacer()
                        Button {
                            deleteControl(id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEditLayout)
                        .help("Remove this control")
                    }

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
                                            face: face,
                                            tintHex: Self.defaultTintHex(for: face, fallingBack: configuration.tintHex)
                                        )
                                    ))
                                }
                            }
                        )) {
                            ForEach(ButtonFace.allCases, id: \.self) { face in
                                Text(face == .standard ? "Standard" : face.rawValue.uppercased()).tag(face)
                            }
                        }
                        HStack {
                            Text("Color")
                            Spacer()
                            ColorPicker(
                                "Color",
                                selection: Binding(
                                    get: {
                                        Color(hex: currentButtonConfiguration(id)?.tintHex
                                              ?? configuration.tintHex) ?? .indigo
                                    },
                                    set: { color in
                                        let hex = color.hexRGB
                                            ?? configuration.tintHex
                                        updateControl(id) { control in
                                            guard case .button(let current) = control.kind else { return control }
                                            return ControlDefinition(
                                                id: control.id,
                                                label: control.label,
                                                kind: .button(ButtonControlConfiguration(
                                                    variant: current.variant,
                                                    hapticsEnabled: current.hapticsEnabled,
                                                    face: current.face,
                                                    tintHex: hex
                                                ))
                                            )
                                        }
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                        }
                    }

                    Divider()
                    Text("ACTION · \(editorState.sessionPack?.seat(at: editorState.selectedSeatIndex)?.label ?? "Seat")")
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
        if let control = draft?.control(id: id), case .trackpad = control.kind {
            trackpadInspector(id)
        } else if let action = draft?.bindings.first(where: { $0.controlID == id })?.action {
            switch action {
            case .keyChord:
                keyChordInspector(id)
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
            case .mouseDrag, .scroll:
                trackpadInspector(id)
            }
        }
    }

    func trackpadInspector(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ONE FINGER DRAG")
                .font(.caption.weight(.semibold))
            Picker("Mouse button", selection: Binding(
                get: { currentMouseDrag(id).button },
                set: { button in
                    let current = currentMouseDrag(id)
                    setAction(id, .mouseDrag(MouseDragAction(
                        gain: current.gain, deadZone: current.deadZone,
                        button: button, modifiers: current.modifiers
                    )), event: .changed)
                }
            )) {
                ForEach(MouseButton.allCases, id: \.self) { button in
                    Text(button.rawValue.capitalized).tag(button)
                }
            }
            Stepper("Drag speed: \(Int(currentMouseDrag(id).gain))", value: Binding(
                get: { currentMouseDrag(id).gain },
                set: { gain in
                    let current = currentMouseDrag(id)
                    setAction(id, .mouseDrag(MouseDragAction(
                        gain: gain, deadZone: current.deadZone,
                        button: current.button, modifiers: current.modifiers
                    )), event: .changed)
                }
            ), in: 1...40, step: 1)
            VStack(alignment: .leading) {
                Text("Dead zone: \(currentMouseDrag(id).deadZone, specifier: "%.2f")")
                Slider(value: Binding(
                    get: { currentMouseDrag(id).deadZone },
                    set: { deadZone in
                        let current = currentMouseDrag(id)
                        setAction(id, .mouseDrag(MouseDragAction(
                            gain: current.gain, deadZone: deadZone,
                            button: current.button, modifiers: current.modifiers
                        )), event: .changed)
                    }
                ), in: 0...0.5)
            }
            ForEach(KeyModifier.allCases, id: \.self) { modifier in
                Toggle(modifier.rawValue.capitalized, isOn: Binding(
                    get: { currentMouseDrag(id).modifiers.contains(modifier) },
                    set: { enabled in
                        let current = currentMouseDrag(id)
                        var modifiers = current.modifiers.filter { $0 != modifier }
                        if enabled { modifiers.append(modifier) }
                        setAction(id, .mouseDrag(MouseDragAction(
                            gain: current.gain, deadZone: current.deadZone,
                            button: current.button, modifiers: modifiers
                        )), event: .changed)
                    }
                ))
            }
            Divider()
            Text("TWO FINGER PINCH")
                .font(.caption.weight(.semibold))
            Text("Scroll to zoom")
                .font(.subheadline)
            Stepper("Zoom speed: \(Int(currentScroll(id).gain))", value: Binding(
                get: { currentScroll(id).gain },
                set: { setAction(id, .scroll(ScrollAction(gain: $0)), event: .pinchChanged) }
            ), in: 1...40, step: 1)
        }
    }

    func keyChordInspector(_ id: String, event: ControlEventKind? = nil) -> some View {
        let captureID = event.map { "\(id)::\($0.rawValue)" } ?? id
        let chord = KeyChordAction(
            key: currentKey(id, event: event),
            modifiers: currentModifiers(id, event: event)
        )
        return ShortcutRecorderField(
            chord: chord,
            isRecording: editorState.capturingShortcutControlID == captureID,
            onStartRecording: {
                editorState.capturingShortcutControlID = captureID
            },
            onCancelRecording: {
                if editorState.capturingShortcutControlID == captureID {
                    editorState.capturingShortcutControlID = nil
                }
            },
            onCapture: { captured in
                setAction(id, .keyChord(captured), event: event)
                editorState.capturingShortcutControlID = nil
            }
        )
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

    func setAction(_ id: String, _ action: ActionDefinition, event: ControlEventKind? = nil) {
        guard let draft, canEditLayout else { return }
        replaceDraft(bindings: draft.bindings.map { binding in
            binding.controlID == id && (event == nil || binding.event == event)
                ? ControlBinding(id: binding.id, controlID: id, event: binding.event, action: action)
                : binding
        })
    }

    func currentKey(_ id: String, event: ControlEventKind? = nil) -> SemanticKey {
        guard let binding = draft?.bindings.first(where: {
            $0.controlID == id && (event == nil || $0.event == event)
        }),
              case .keyChord(let action) = binding.action else { return .rightArrow }
        return action.key
    }

    func currentModifiers(_ id: String, event: ControlEventKind? = nil) -> [KeyModifier] {
        guard let binding = draft?.bindings.first(where: {
            $0.controlID == id && (event == nil || $0.event == event)
        }),
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

    func currentMouseDrag(_ id: String) -> MouseDragAction {
        guard let binding = draft?.binding(controlID: id, event: .changed),
              case .mouseDrag(let action) = binding.action else {
            return MouseDragAction(gain: 10, deadZone: 0, button: .left, modifiers: [])
        }
        return action
    }

    func currentScroll(_ id: String) -> ScrollAction {
        guard let binding = draft?.binding(controlID: id, event: .pinchChanged),
              case .scroll(let action) = binding.action else {
            return ScrollAction(gain: 10)
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
    let title: String
    let subtitle: String?
    let systemImage: String?
    let occupiesLayout: Bool
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
            if occupiesLayout {
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

                VStack(spacing: 2) {
                    Text(title)
                        .font(subtitle == nil
                              ? .caption.weight(.semibold)
                              : .title3.weight(.heavy))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.medium))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(8)
                .minimumScaleFactor(0.55)
                .lineLimit(2)
                .allowsHitTesting(false)
            } else {
                VStack(spacing: 4) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Text(subtitle ?? title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }

            if isSelected && occupiesLayout {
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
        .zIndex(isSelected ? 20 : (occupiesLayout ? 0 : 15))
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

private struct ShortcutRecorderField: View {
    let chord: KeyChordAction
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCancelRecording: () -> Void
    let onCapture: (KeyChordAction) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopMonitoring()
                onCancelRecording()
            } else {
                onStartRecording()
            }
        } label: {
            HStack {
                Text(isRecording ? "Press shortcut…" : chord.displayString)
                    .font(.body.monospaced())
                    .foregroundStyle(isRecording ? .secondary : .primary)
                Spacer()
                Text(isRecording ? "Esc to cancel" : "Click to record")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, recording in
            if recording {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
        .onDisappear {
            stopMonitoring()
            if isRecording {
                onCancelRecording()
            }
        }
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Pure modifier presses wait for a real key.
            if Self.isModifierKeyCode(event.keyCode) {
                return nil
            }
            // Esc alone cancels recording.
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                stopMonitoring()
                onCancelRecording()
                return nil
            }
            guard let key = SemanticKey.from(keyCode: event.keyCode) else {
                return nil
            }
            var modifiers: [KeyModifier] = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.append(.command) }
            if flags.contains(.shift) { modifiers.append(.shift) }
            if flags.contains(.option) { modifiers.append(.option) }
            if flags.contains(.control) { modifiers.append(.control) }
            stopMonitoring()
            onCapture(KeyChordAction(key: key, modifiers: modifiers))
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        // Shift, Control, Option, Command (left/right)
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }
}

private extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var hexRGB: String? {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor.usingColorSpace(.sRGB) else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

private struct AssetLibraryTile: View {
    let asset: ControlCapabilityDescriptor
    let isEnabled: Bool
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: asset.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                Text(asset.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(asset.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.secondary.opacity(0.25))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(asset.summary)
    }
}
