import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppState {
    var archiveURL: URL?
    var listing: ArchiveListing?
    var selected: [ArchiveNode] = []
    var password: String = ""
    var searchText: String = ""
    var isLoading = false
    var isExtracting = false
    var isPacking = false
    var activityTitle = ""
    var progressText = ""
    var extractProgress = ExtractProgress.idle
    var errorMessage: String?
    var infoMessage: String?
    var showPasswordSheet = false
    var passwordPrompt = "Dieses Archiv ist passwortgeschützt."
    var pendingOpenURL: URL?
    var pendingExtract: PendingExtract?
    var showExtractSuccess = false
    var lastExtractedFolder: URL?
    var showCreateSheet = false
    var createSources: [URL] = []
    var createFolder: URL?
    var createName = ""
    var createFormat: CreateFormat = .zip
    var createParts = false
    var createPartAmount = ""
    var createPartUnit: PartUnit = .mb
    private var dragExtractItems: [ExtractItem] = []
    private var dropExtractDirectory: URL?
    private var operation = 0
    private var activeOpenPath: String?
    private var scanInFlight = false

    var isBusy: Bool { isLoading || isExtracting || isPacking }

    struct PendingExtract {
        var archive: URL
        var indexes: [Int]?
        var paths: [String]?
        var destination: URL
        var createContainingDirectory: Bool?
        var reveal: Bool
    }

    var hasArchive: Bool { listing != nil }
    var formatLabel: String { listing?.formatName ?? "" }

    var volumeLabel: String? {
        guard let listing, listing.volumeCount > 1 else { return nil }
        return L10n.t("status.volumes", listing.volumeCount)
    }

    var statusText: String {
        guard let listing else {
            return L10n.t("status.idle")
        }
        let archive = Formatters.bytes(listing.archiveBytes)
        let content = Formatters.bytes(listing.totalUncompressed)
        if !selected.isEmpty {
            let files = selected.reduce(0) { $0 + $1.fileCount }
            let size = selected.reduce(Int64(0)) { $0 + $1.recursiveUncompressedSize }
            if listing.volumeCount > 1 {
                return L10n.t(
                    "status.selected.volumes",
                    selected.count,
                    files,
                    Formatters.bytes(size),
                    listing.volumeCount,
                    archive
                )
            }
            return L10n.t("status.selected", selected.count, files, Formatters.bytes(size))
        }
        if listing.volumeCount > 1 {
            return L10n.t("status.listing.volumes", listing.volumeCount, listing.fileCount, content, archive)
        }
        if listing.archiveBytes > 0 {
            return L10n.t("status.listing.sizes", listing.fileCount, content, archive)
        }
        return L10n.t("status.listing", listing.fileCount, content, listing.formatName)
    }

    var windowTitle: String {
        archiveURL?.lastPathComponent ?? "Unarchive"
    }

    func closeArchive() {
        if isExtracting || isLoading {
            cancelWork()
        }
        archiveURL = nil
        listing = nil
        selected = []
        searchText = ""
        password = ""
        extractProgress = .idle
    }

    func cancelWork() {
        ArchiveEngine.cancelActive()
    }

    func createArchive(preferred: CreateFormat? = nil) {
        guard !isBusy else {
            errorMessage = L10n.t("extract.busy")
            return
        }
        guard let urls = ArchiveCreator.chooseSources() else { return }
        presentCreate(urls, preferred: preferred)
    }

    func presentCreate(_ urls: [URL], preferred: CreateFormat?) {
        guard !urls.isEmpty else { return }
        guard !isBusy else {
            errorMessage = L10n.t("extract.busy")
            return
        }
        let format = preferred ?? SettingsStore.shared.defaultCreateFormat
        createSources = urls
        createFolder = urls[0].deletingLastPathComponent()
        createFormat = format
        createParts = false
        createPartAmount = ""
        createPartUnit = .mb
        createName = ArchiveCreator.proposedName(for: urls, format: format)
        showCreateSheet = true
    }

    func commitCreate() {
        let format = createFormat
        let volumeBytes = resolvedPartBytes
        var name = createName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let folder = createFolder, !createSources.isEmpty else { return }
        if format.supportsSplit, createParts, volumeBytes == nil { return }
        if format == .rar, !ArchiveCreator.rarAvailable {
            errorMessage = L10n.t("rar.missing")
            return
        }
        name = ArchiveCreator.name(keepingBaseOf: name, format: format)
        let destination = folder.appendingPathComponent(name)
        let urls = createSources
        showCreateSheet = false
        SettingsStore.shared.defaultCreateFormat = format
        Task { await pack(urls: urls, to: destination, format: format, volumeBytes: volumeBytes, reveal: true) }
    }

    func packNextTo(_ urls: [URL]) async {
        presentCreate(urls, preferred: SettingsStore.shared.defaultCreateFormat)
    }

    var resolvedPartBytes: Int64? {
        guard createFormat.supportsSplit, createParts else { return nil }
        let text = createPartAmount
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value > 0, value.isFinite else { return nil }
        let bytes = value * Double(createPartUnit.bytes)
        guard bytes >= 1_048_576, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    func pack(urls: [URL], to destination: URL, format: CreateFormat, volumeBytes: Int64? = nil, reveal: Bool) async {
        let op = nextOperation()
        isPacking = true
        isLoading = false
        isExtracting = false
        activityTitle = L10n.t("packing")
        progressText = L10n.t("packing")
        errorMessage = nil
        let started = Date()
        extractProgress = ExtractProgress(
            destination: destination.path,
            archiveName: destination.lastPathComponent,
            statusLine: L10n.t("preparing")
        )
        defer { finish(op) }
        do {
            try await ArchiveCreator.create(from: urls, to: destination, format: format, volumeBytes: volumeBytes) { update in
                Task { @MainActor in
                    guard self.operation == op else { return }
                    var current = self.extractProgress
                    current.currentFile = update.file
                    current.statusLine = update.file.isEmpty ? L10n.t("packing") : update.file
                    current.fraction = update.fraction
                    current.isDeterminate = update.fraction > 0 || update.filesTotal > 0
                    current.bytesDone = update.bytesDone
                    current.bytesTotal = max(update.bytesTotal, current.bytesTotal)
                    current.filesDone = update.filesDone
                    current.filesTotal = update.filesTotal
                    current.estimatesArchive = true
                    current.elapsed = Date().timeIntervalSince(started)
                    if update.fraction > 0.015, current.elapsed >= 1, update.fraction < 1 {
                        let remaining = current.elapsed * (1 - update.fraction) / update.fraction
                        current.eta = remaining.isFinite && remaining >= 0 ? remaining : nil
                        if update.bytesDone > 0 {
                            let raw = Double(update.bytesDone) / update.fraction
                            if current.expectedBytes == 0 {
                                current.expectedBytes = Int64(raw)
                            } else {
                                current.expectedBytes = Int64(Double(current.expectedBytes) * 0.65 + raw * 0.35)
                            }
                            current.bytesPerSecond = Double(update.bytesDone) / current.elapsed
                        }
                    }
                    self.extractProgress = current
                    self.progressText = current.statusLine
                }
            }
            guard operation == op else { return }
            let made = ArchiveCreator.producedFiles(at: destination)
            if made.count > 1 {
                infoMessage = L10n.t("packed.parts", made.count, destination.deletingLastPathComponent().path)
            } else {
                infoMessage = L10n.t("packed.to.time", destination.path, Formatters.duration(Date().timeIntervalSince(started)))
            }
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting(made.isEmpty ? [destination] : made)
            }
        } catch ArchiveError.cancelled {
            guard operation == op else { return }
            infoMessage = L10n.t("extract.cancelled")
        } catch {
            guard operation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    func openArchive() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("open.archive")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL, password override: String? = nil) async {
        guard SupportedArchives.isArchive(url) || url.pathExtension.isEmpty == false else {
            errorMessage = ArchiveError.notAnArchive.localizedDescription
            return
        }

        let resolvedEarly = ArchiveEngine.firstVolume(for: url)
        let openKey = resolvedEarly.standardizedFileURL.path
        if activeOpenPath == openKey { return }
        if override == nil,
           listing != nil,
           archiveURL?.standardizedFileURL.path == openKey {
            return
        }

        let op = nextOperation()
        activeOpenPath = openKey
        if isExtracting || isPacking {
            cancelWork()
        }
        isPacking = false
        isExtracting = false
        isLoading = true
        activityTitle = L10n.t("reading")
        errorMessage = nil
        progressText = L10n.t("reading")
        extractProgress = ExtractProgress(
            currentFile: url.lastPathComponent,
            destination: url.deletingLastPathComponent().path,
            archiveName: url.lastPathComponent,
            statusLine: L10n.t("reading")
        )
        defer {
            if activeOpenPath == openKey { activeOpenPath = nil }
            if operation == op {
                isLoading = false
                if !isExtracting && !isPacking {
                    extractProgress = .idle
                    activityTitle = ""
                }
            }
        }

        let resolved = ArchiveEngine.firstVolume(for: url)
        var usedPassword = override ?? password

        if usedPassword.isEmpty {
            do {
                let result = try await ArchiveEngine.list(resolved, password: nil)
                guard operation == op else { return }
                applyOpened(result, url: resolved, password: "")
                return
            } catch ArchiveError.cancelled {
                guard operation == op else { return }
                infoMessage = L10n.t("extract.cancelled")
                return
            } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
                if SettingsStore.shared.rememberPasswords {
                    extractProgress.statusLine = L10n.t("password.trying")
                    progressText = L10n.t("password.trying")
                    for saved in PasswordVault.recent() {
                        if operation != op || ArchiveEngine.isCancelled {
                            guard operation == op else { return }
                            infoMessage = L10n.t("extract.cancelled")
                            return
                        }
                        if await ArchiveEngine.acceptsPassword(resolved, password: saved) {
                            usedPassword = saved
                            break
                        }
                    }
                }
                guard operation == op else { return }
                if usedPassword.isEmpty {
                    password = ""
                    pendingOpenURL = resolved
                    passwordPrompt = L10n.t("password.protected", resolved.lastPathComponent)
                    showPasswordSheet = true
                    return
                }
            } catch {
                guard operation == op else { return }
                errorMessage = error.localizedDescription
                return
            }
        }

        do {
            let result = try await ArchiveEngine.list(resolved, password: usedPassword.isEmpty ? nil : usedPassword)
            guard operation == op else { return }
            applyOpened(result, url: resolved, password: usedPassword)
            if !usedPassword.isEmpty, SettingsStore.shared.rememberPasswords {
                PasswordVault.remember(usedPassword)
            }
        } catch ArchiveError.cancelled {
            guard operation == op else { return }
            infoMessage = L10n.t("extract.cancelled")
        } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
            guard operation == op else { return }
            password = ""
            pendingOpenURL = resolved
            passwordPrompt = (override != nil) || !usedPassword.isEmpty
                ? L10n.t("password.wrong")
                : L10n.t("password.protected", resolved.lastPathComponent)
            showPasswordSheet = true
        } catch {
            guard operation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyOpened(_ result: ArchiveListing, url: URL, password usedPassword: String) {
        archiveURL = url
        listing = result
        selected = []
        searchText = ""
        password = usedPassword
        pendingOpenURL = nil
        showPasswordSheet = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        SettingsStore.shared.remember(url)
    }

    func submitPassword(_ value: String) {
        showPasswordSheet = false
        if let pendingExtract {
            Task { await extract(pendingExtract, password: value) }
        } else if let pendingOpenURL {
            Task { await open(pendingOpenURL, password: value) }
        }
    }

    func extractSelected(to destination: URL?, createFolder: Bool?, reveal: Bool) {
        guard let archiveURL else { return }
        if isExtracting {
            errorMessage = L10n.t("extract.busy")
            return
        }
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let panel = NSOpenPanel()
            panel.title = L10n.t("choose.folder")
            panel.prompt = L10n.t("unpack")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = archiveURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dest = url
        }

        let indexes: [Int]?
        let paths: [String]?
        if selected.isEmpty {
            indexes = nil
            paths = nil
        } else {
            indexes = Array(Set(selected.flatMap(\.descendantIndexes))).sorted()
            paths = selected.map(\.fullPath).filter { !$0.isEmpty }
        }

        let job = PendingExtract(
            archive: archiveURL,
            indexes: indexes,
            paths: paths,
            destination: dest,
            createContainingDirectory: createFolder,
            reveal: reveal
        )
        Task { await extract(job, password: password) }
    }

    func extractHere(createFolder: Bool) {
        guard let archiveURL else { return }
        extractSelected(
            to: archiveURL.deletingLastPathComponent(),
            createFolder: createFolder,
            reveal: SettingsStore.shared.revealAfterExtract
        )
    }

    func extract(archive url: URL, mode: FinderExtractMode, destination: URL? = nil) async {
        await open(url)
        let opened = ArchiveEngine.firstVolume(for: url).standardizedFileURL.path
        guard listing != nil, archiveURL?.standardizedFileURL.path == opened else { return }

        let dest: URL
        if let destination {
            dest = destination
        } else {
            dest = url.deletingLastPathComponent()
        }

        let createFolder: Bool?
        switch mode {
        case .here:
            createFolder = false
        case .intoFolder:
            createFolder = true
        case .choose:
            createFolder = nil
        }

        if mode == .choose {
            extractSelected(to: nil, createFolder: nil, reveal: true)
            return
        }

        let job = PendingExtract(
            archive: url,
            indexes: nil,
            paths: nil,
            destination: dest,
            createContainingDirectory: createFolder,
            reveal: true
        )
        await extract(job, password: password)
    }

    func extract(_ job: PendingExtract, password usedPassword: String) async {
        if isExtracting || isPacking {
            errorMessage = L10n.t("extract.busy")
            return
        }
        let op = nextOperation()
        isExtracting = true
        activityTitle = L10n.t("extracting")
        progressText = L10n.t("extracting")
        errorMessage = nil
        pendingExtract = nil
        extractProgress = ExtractProgress(
            isDeterminate: (listing?.totalUncompressed ?? 0) > 0,
            destination: job.destination.path,
            archiveName: job.archive.lastPathComponent,
            statusLine: L10n.t("extracting"),
            bytesTotal: listing?.totalUncompressed ?? 0,
            filesTotal: listing?.fileCount ?? 0
        )
        defer { finish(op) }

        let started = Date()
        do {
            try await runExtract(job, password: usedPassword)
            guard operation == op else { return }
            lastExtractedFolder = job.destination
            password = usedPassword
            if !usedPassword.isEmpty, SettingsStore.shared.rememberPasswords {
                PasswordVault.remember(usedPassword)
            }
            infoMessage = L10n.t("extracted.to.time", job.destination.path, Formatters.duration(Date().timeIntervalSince(started)))
            if job.reveal {
                reveal(job.destination)
            }
        } catch ArchiveError.cancelled {
            guard operation == op else { return }
            infoMessage = L10n.t("extract.cancelled")
        } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
            guard operation == op else { return }
            password = ""
            pendingExtract = job
            pendingOpenURL = nil
            passwordPrompt = L10n.t("password.needed.extract")
            showPasswordSheet = true
        } catch {
            guard operation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    func beginDragExtract(_ nodes: [ArchiveNode]) {
        dragExtractItems = nodes.map(ExtractItem.init)
        dropExtractDirectory = nil
    }

    func fulfillDrop(entry: ExtractItem, destination promised: URL) async throws {
        guard let archiveURL else {
            throw ArchiveError.notAnArchive
        }
        let destDir = promised.deletingLastPathComponent()
        let items = dragExtractItems.isEmpty ? [entry] : dragExtractItems

        if isExtracting, dropExtractDirectory == destDir {
            while isExtracting {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try ArchiveEngine.placeExtractedItem(entry, from: destDir, onto: promised)
            return
        }
        if isExtracting {
            throw ArchiveError.busy
        }

        dropExtractDirectory = destDir
        let paths = items.map(\.fullPath).filter { !$0.isEmpty }
        let sizes = fileSizeMap()
        let bytes = items.reduce(Int64(0)) { partial, item in
            if item.isDirectory { return listing?.totalUncompressed ?? partial }
            return partial + (sizes[item.fullPath] ?? sizes[item.name] ?? 0)
        }
        let files = items.reduce(0) { total, item in
            if item.isDirectory { return listing?.fileCount ?? total }
            return total + 1
        }
        let job = PendingExtract(
            archive: archiveURL,
            indexes: items.flatMap(\.indexes).nilIfEmpty,
            paths: paths.nilIfEmpty,
            destination: destDir,
            createContainingDirectory: false,
            reveal: false
        )
        try await performDropExtract(job, password: password, bytes: bytes, files: files, sizes: sizes)
        try ArchiveEngine.placeExtractedItem(entry, from: destDir, onto: promised)
    }

    private func performDropExtract(
        _ job: PendingExtract,
        password usedPassword: String,
        bytes: Int64,
        files: Int,
        sizes: [String: Int64]
    ) async throws {
        isExtracting = true
        activityTitle = L10n.t("extracting")
        errorMessage = nil
        extractProgress = ExtractProgress(
            isDeterminate: bytes > 0 || files > 0,
            destination: job.destination.path,
            archiveName: job.archive.lastPathComponent,
            statusLine: L10n.t("extracting"),
            bytesTotal: bytes > 0 ? bytes : (listing?.totalUncompressed ?? 0),
            filesTotal: files > 0 ? files : (listing?.fileCount ?? 0)
        )
        let op = nextOperation()
        defer { finish(op) }
        try await runExtract(job, password: usedPassword, bytesTotal: bytes, filesTotal: files, sizes: sizes)
        guard operation == op else { return }
        lastExtractedFolder = job.destination
        password = usedPassword
    }

    private func runExtract(
        _ job: PendingExtract,
        password usedPassword: String,
        bytesTotal: Int64? = nil,
        filesTotal: Int? = nil,
        sizes: [String: Int64]? = nil
    ) async throws {
        let map = sizes ?? fileSizeMap()
        try? FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
        let destination = job.destination
        let baseline = await Task.detached(priority: .utility) {
            ArchiveEngine.allocatedBytes(at: destination)
        }.value
        let total = bytesTotal ?? listing?.totalUncompressed ?? 0
        let started = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshExtractProgress(
                    destination: job.destination,
                    baseline: baseline,
                    totalBytes: total,
                    started: started
                )
            }
        }
        timer.tolerance = 0.25
        defer { timer.invalidate() }
        refreshExtractProgress(destination: job.destination, baseline: baseline, totalBytes: total, started: started)

        try await ArchiveEngine.extract(
            archive: job.archive,
            password: usedPassword.isEmpty ? nil : usedPassword,
            indexes: job.indexes,
            paths: job.paths,
            destination: job.destination,
            createContainingDirectory: job.createContainingDirectory,
            bytesTotal: bytesTotal ?? listing?.totalUncompressed ?? 0,
            filesTotal: filesTotal ?? listing?.fileCount ?? 0,
            fileSizes: map
        ) { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                var current = self.extractProgress
                current.currentFile = update.currentFile
                current.volume = update.volume
                current.statusLine = update.statusLine
                current.filesDone = max(current.filesDone, update.filesDone)
                self.extractProgress = current
                self.progressText = update.currentFile.isEmpty ? update.statusLine : update.currentFile
            }
        }
    }

    private func refreshExtractProgress(destination: URL, baseline: Int64, totalBytes: Int64, started: Date) {
        var current = extractProgress
        current.elapsed = Date().timeIntervalSince(started)
        extractProgress = current
        guard !scanInFlight else { return }
        scanInFlight = true
        let op = operation
        Task.detached(priority: .utility) { [weak self] in
            let written = max(0, ArchiveEngine.allocatedBytes(at: destination) - baseline)
            await self?.applyScannedBytes(written, operation: op, totalBytes: totalBytes, started: started)
        }
    }

    private func applyScannedBytes(_ written: Int64, operation op: Int, totalBytes: Int64, started: Date) {
        scanInFlight = false
        guard operation == op, isExtracting else { return }
        var current = extractProgress
        current.elapsed = Date().timeIntervalSince(started)
        if written > current.bytesDone {
            current.bytesDone = written
        }
        current.bytesTotal = totalBytes
        if totalBytes > 0 {
            current.fraction = min(Double(current.bytesDone) / Double(totalBytes), 0.99)
            current.isDeterminate = true
        }
        if current.fraction >= 0.04, current.elapsed >= 20, current.bytesDone > 50_000_000, current.fraction < 1 {
            let remaining = current.elapsed / current.fraction - current.elapsed
            current.eta = remaining.isFinite && remaining >= 0 ? remaining : nil
        } else if current.fraction < 1 {
            current.eta = nil
        }
        extractProgress = current
    }

    private func nextOperation() -> Int {
        operation &+= 1
        return operation
    }

    private func finish(_ op: Int) {
        guard operation == op else { return }
        isLoading = false
        isExtracting = false
        isPacking = false
        extractProgress = .idle
        activityTitle = ""
    }

    private func fileSizeMap() -> [String: Int64] {
        guard let listing else { return [:] }
        var map: [String: Int64] = [:]
        for file in listing.root.flattenedFiles() {
            map[file.fullPath] = file.uncompressedSize
            map[file.name] = file.uncompressedSize
        }
        return map
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openSelection() {
        guard let archiveURL, let node = selected.first else { return }
        Task { await preview(node, from: archiveURL, open: true) }
    }

    func preview(_ node: ArchiveNode, from archive: URL, open: Bool) async {
        let op = nextOperation()
        isExtracting = true
        activityTitle = L10n.t("preparing")
        progressText = L10n.t("preparing")
        defer { finish(op) }
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("UnarchivePreview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try await ArchiveEngine.extract(
                archive: archive,
                password: password.isEmpty ? nil : password,
                indexes: node.descendantIndexes,
                paths: [node.fullPath],
                destination: temp,
                createContainingDirectory: false
            )
            let item = ArchiveEngineTemp.locate(named: node.name, fullPath: node.fullPath, in: temp)
                ?? temp
            if open {
                NSWorkspace.shared.open(item)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([item])
            }
        } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
            guard operation == op else { return }
            passwordPrompt = L10n.t("password.needed.open")
            showPasswordSheet = true
        } catch {
            guard operation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    func testArchive() {
        guard let archiveURL else { return }
        Task {
            let op = nextOperation()
            isLoading = true
            activityTitle = L10n.t("testing")
            progressText = L10n.t("testing")
            defer { finish(op) }
            do {
                let output = try await ArchiveEngine.test(
                    archive: archiveURL,
                    password: password.isEmpty ? nil : password
                )
                let failed = output.lowercased().contains("failed") || output.lowercased().contains("fehl")
                infoMessage = failed
                    ? L10n.t("test.fail", output)
                    : L10n.t("test.ok")
            } catch ArchiveError.cancelled {
                guard operation == op else { return }
                infoMessage = L10n.t("extract.cancelled")
            } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
                guard operation == op else { return }
                passwordPrompt = L10n.t("password.needed.test")
                showPasswordSheet = true
            } catch {
                guard operation == op else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func createZip() {
        createArchive()
    }

    func becomeDefaultHandler() {
        Task {
            let extensions = ["rar", "cbr", "zip", "zipx", "7z", "tar", "gz", "bz2", "xz", "tgz", "tbz", "iso", "cab", "lha", "lzh", "jar"]
            var assigned = 0
            for ext in extensions {
                guard let type = UTType(filenameExtension: ext) else { continue }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                    assigned += 1
                } catch {
                    continue
                }
            }
            infoMessage = assigned > 0
                ? L10n.t("default.ok")
                : L10n.t("default.fail")
        }
    }
}

enum FinderExtractMode {
    case here
    case intoFolder
    case choose
}

enum ArchiveEngineTemp {
    static func locate(named name: String, fullPath: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(fullPath)
        if fm.fileExists(atPath: direct.path) { return direct }
        let byName = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: byName.path) { return byName }
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.lastPathComponent == name {
                return file
            }
        }
        return nil
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
