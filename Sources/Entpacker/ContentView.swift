import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(SettingsStore.self) private var settings
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if state.hasArchive {
                ArchiveOutlineView()
            } else {
                WelcomeView(isDropTargeted: isDropTargeted)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(state.windowTitle)
        .toolbar { toolbarContent }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if state.isLoading || state.isExtracting {
                ProgressOverlay(
                    progress: state.extractProgress,
                    fallback: state.progressText,
                    showsCancel: true,
                    onCancel: { state.cancelWork() }
                )
            }
        }
        .sheet(isPresented: $state.showPasswordSheet) {
            PasswordSheet()
        }
        .alert(L10n.t("notice"), isPresented: Binding(
            get: { state.infoMessage != nil },
            set: { if !$0 { state.infoMessage = nil } }
        )) {
            Button(L10n.t("ok"), role: .cancel) { state.infoMessage = nil }
        } message: {
            Text(state.infoMessage ?? "")
        }
        .alert(L10n.t("error"), isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button(L10n.t("ok"), role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .frame(minWidth: 840, minHeight: 560)
        .id(settings.revision)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if state.hasArchive {
                Button {
                    state.closeArchive()
                } label: {
                    Label(L10n.t("close.archive"), systemImage: "xmark")
                }
                .help(L10n.t("close.archive"))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(L10n.t("open"), systemImage: "folder") {
                state.openArchive()
            }
            .help(L10n.t("open.archive"))

            Button(L10n.t("extract.to"), systemImage: "square.and.arrow.down") {
                state.extractSelected(to: nil, createFolder: nil, reveal: settings.revealAfterExtract)
            }
            .disabled(!state.hasArchive || state.isExtracting)
            .help(L10n.t("extract.to.help"))

            Button(L10n.t("extract.here"), systemImage: "tray.and.arrow.down") {
                state.extractHere(createFolder: false)
            }
            .disabled(!state.hasArchive || state.isExtracting)
            .help(L10n.t("extract.here.help"))

            Button(L10n.t("extract.folder"), systemImage: "folder.badge.plus") {
                state.extractHere(createFolder: true)
            }
            .disabled(!state.hasArchive || state.isExtracting)
            .help(L10n.t("extract.folder.help"))

            Button(L10n.t("test"), systemImage: "checkmark.seal") {
                state.testArchive()
            }
            .disabled(!state.hasArchive)

            Button(L10n.t("create"), systemImage: "plus.square.on.square") {
                state.createArchive()
            }
            .help(L10n.t("create.archive"))
        }

        ToolbarItem(placement: .automatic) {
            if state.hasArchive {
                TextField(L10n.t("search"), text: Binding(
                    get: { state.searchText },
                    set: { state.searchText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if state.hasArchive {
                Text(state.formatLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .help(L10n.t("status.format.help", state.formatLabel))
                if let volumes = state.volumeLabel {
                    Text(volumes)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .help(L10n.t("status.volumes.help"))
                }
            }
            Text(state.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            Text(L10n.t("created.by"))
                .foregroundStyle(.tertiary)
            if let url = state.archiveURL {
                Text(url.deletingLastPathComponent().path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let urlItem = item as? URL {
                    url = urlItem
                } else if let text = item as? String {
                    url = URL(fileURLWithPath: text)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    if SupportedArchives.isArchive(url) {
                        await state.open(url)
                    } else {
                        state.errorMessage = L10n.t("not.supported", url.lastPathComponent)
                    }
                }
            }
        }
        return true
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var state
    @Environment(SettingsStore.self) private var settings
    let isDropTargeted: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("Unarchive")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(L10n.t("welcome.title"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(L10n.t("welcome.subtitle"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                }
                .padding(.top, 28)

                dropZone

                HStack(spacing: 12) {
                    Button(L10n.t("open.archive")) { state.openArchive() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(L10n.t("create.archive")) { state.createArchive() }
                        .controlSize(.large)
                }

                formatSection
                recentSection

                VStack(spacing: 4) {
                    Text(L10n.t("credits"))
                        .font(.subheadline.weight(.medium))
                    Text(L10n.t("copyright"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            Text(L10n.t("drop.title"))
                .font(.headline)
            Text(L10n.t("drop.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
        )
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            formatRow(title: L10n.t("formats.unpack"), chips: SupportedArchives.unpackChips)
            formatRow(title: L10n.t("formats.pack"), chips: SupportedArchives.packChips)
            Text(L10n.t("pack.note"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatRow(title: String, chips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowChips(items: chips)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("recent").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if settings.recents.isEmpty {
                Text(L10n.t("no.recent"))
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            } else {
                ForEach(settings.recents, id: \.path) { url in
                    Button {
                        Task { await state.open(url) }
                    } label: {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(url.lastPathComponent)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowChips: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct PasswordSheet: View {
    @Environment(AppState.self) private var state
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("password"))
                .font(.headline)
            Text(state.passwordPrompt)
                .foregroundStyle(.secondary)
            SecureField(L10n.t("password.enter"), text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button(L10n.t("cancel")) {
                    state.showPasswordSheet = false
                    state.pendingOpenURL = nil
                    state.pendingExtract = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.t("unpack")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !value.isEmpty else { return }
        state.submitPassword(value)
    }
}

struct ProgressOverlay: View {
    let progress: ExtractProgress
    let fallback: String
    var showsCancel: Bool = false
    var onCancel: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("extracting"))
                    .font(.headline)
                if progress.isDeterminate {
                    ProgressView(value: min(max(progress.fraction, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text(progress.percentText.isEmpty ? L10n.t("wait") : progress.percentText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Spacer()
                    if let eta = progress.eta, progress.fraction > 0, progress.fraction < 1 {
                        Text(L10n.t("progress.eta", Formatters.duration(eta)))
                            .foregroundStyle(.secondary)
                    } else if progress.isDeterminate, progress.fraction < 1, progress.elapsed >= 2 {
                        Text(L10n.t("progress.eta.wait"))
                            .foregroundStyle(.tertiary)
                    }
                }
                infoRow(L10n.t("progress.file"), fileLabel)
                infoRow(L10n.t("progress.to"), progress.destination.isEmpty ? "—" : progress.destination)
                if !progress.volume.isEmpty {
                    infoRow(L10n.t("progress.part"), (progress.volume as NSString).lastPathComponent)
                }
                Text(sizeLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(L10n.t("progress.elapsed", Formatters.duration(progress.elapsed)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if showsCancel {
                    HStack {
                        Spacer()
                        Button(L10n.t("extract.cancel"), role: .cancel, action: onCancel)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(22)
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .ignoresSafeArea()
        .animation(nil, value: progress.currentFile)
    }

    private var fileLabel: String {
        if !progress.currentFile.isEmpty { return progress.currentFile }
        if !progress.statusLine.isEmpty { return progress.statusLine }
        if !fallback.isEmpty { return fallback }
        return "—"
    }

    private var sizeLabel: String {
        var parts: [String] = []
        if progress.bytesTotal > 0 {
            parts.append("\(Formatters.bytes(progress.bytesDone)) / \(Formatters.bytes(progress.bytesTotal))")
        }
        if progress.filesTotal > 0 {
            parts.append(L10n.t("progress.files", progress.filesDone, progress.filesTotal))
        }
        return parts.isEmpty ? fallback : parts.joined(separator: "  ·  ")
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
