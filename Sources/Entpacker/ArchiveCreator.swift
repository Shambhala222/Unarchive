import AppKit
import Foundation

struct PackUpdate: Sendable {
    var file: String = ""
    var fraction: Double = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
}

final class PackMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var update = PackUpdate()
    private var filesDone = 0
    private var fileFraction = 0.0

    init(bytesTotal: Int64, file: String) {
        update.bytesTotal = bytesTotal
        update.file = file
    }

    func noteBytes(_ written: Int64) -> PackUpdate {
        lock.lock()
        update.bytesDone = max(update.bytesDone, written)
        let snapshot = update
        lock.unlock()
        return snapshot
    }

    func noteOverall(name: String, fraction: Double) -> PackUpdate {
        lock.lock()
        if !name.isEmpty { update.file = name }
        update.fraction = min(max(fraction, update.fraction), 0.99)
        let snapshot = update
        lock.unlock()
        return snapshot
    }

    func noteFile(name: String, fileFraction: Double?, finished: Bool, filesTotal: Int) -> PackUpdate {
        lock.lock()
        update.filesTotal = filesTotal
        if !name.isEmpty { update.file = name }
        if finished {
            filesDone += 1
            self.fileFraction = 0
        } else if let fileFraction {
            self.fileFraction = min(max(fileFraction, 0), 0.99)
        }
        update.filesDone = filesDone
        if filesTotal > 0 {
            let overall = (Double(filesDone) + self.fileFraction) / Double(filesTotal)
            update.fraction = min(max(overall, 0), 0.99)
        } else if fileFraction != nil, !finished {
            update.fraction = self.fileFraction
        }
        let snapshot = update
        lock.unlock()
        return snapshot
    }

    func advance(name: String, filesTotal: Int) -> PackUpdate {
        noteFile(name: name, fileFraction: nil, finished: true, filesTotal: filesTotal)
    }
}

enum ArchiveCreator {
    @MainActor
    static func chooseSources() -> [URL]? {
        let source = NSOpenPanel()
        source.title = L10n.t("create.choose")
        source.prompt = L10n.t("open")
        source.canChooseFiles = true
        source.canChooseDirectories = true
        source.allowsMultipleSelection = true
        guard source.runModal() == .OK, !source.urls.isEmpty else { return nil }
        return source.urls
    }

    @MainActor
    static func chooseDestination(for urls: [URL], format: CreateFormat) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.t("create.save")
        panel.message = L10n.t("create.format", format.title)
        panel.nameFieldStringValue = suggestedName(for: urls, format: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        if urls.count == 1 {
            panel.directoryURL = urls[0].deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, var destination = panel.url else { return nil }
        if !destination.lastPathComponent.lowercased().hasSuffix(".\(format.fileExtension)") {
            destination.deletePathExtension()
            destination = destination.appendingPathExtension(format.fileExtension)
        }
        return destination
    }

    static func destinationNextTo(_ urls: [URL], format: CreateFormat) -> URL? {
        guard let first = urls.first else { return nil }
        let folder = first.deletingLastPathComponent()
        let name = suggestedName(for: urls, format: format)
        var destination = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = archiveBaseName(name, format: format)
            destination = folder.appendingPathComponent("\(base)-\(index).\(format.fileExtension)")
            index += 1
            if index > 999 { return nil }
        }
        return destination
    }

    static var rarAvailable: Bool { rarExecutable() != nil }

    static func rarExecutable() -> URL? {
        for path in ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func proposedName(for urls: [URL], format: CreateFormat) -> String {
        suggestedName(for: urls, format: format)
    }

    static func name(keepingBaseOf current: String, format: CreateFormat) -> String {
        var base = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = CreateFormat.allCases
            .map { ".\($0.fileExtension)" }
            .sorted { $0.count > $1.count }
        for suffix in suffixes where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        if base.isEmpty { base = "Archive" }
        return "\(base).\(format.fileExtension)"
    }

    static func producedFiles(at destination: URL) -> [URL] {
        let folder = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let stem = destination.deletingPathExtension().lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let matches = items.filter { item in
            let file = item.lastPathComponent
            if file == name { return true }
            if file.hasPrefix(name + ".") { return true }
            if file.hasPrefix(stem + ".part"), file.lowercased().hasSuffix(".rar") { return true }
            return false
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if matches.isEmpty, FileManager.default.fileExists(atPath: destination.path) {
            return [destination]
        }
        return matches
    }

    static func create(
        from urls: [URL],
        to destination: URL,
        format: CreateFormat,
        volumeBytes: Int64? = nil,
        onProgress: @escaping @Sendable (PackUpdate) -> Void
    ) async throws {
        let sources = urls.filter { !MacJunk.isJunk($0.lastPathComponent) }
        guard !sources.isEmpty else {
            throw ArchiveError.extractFailed(L10n.t("create.empty"))
        }
        if sources.contains(where: { destinationIsInside($0, destination: destination) }) {
            throw ArchiveError.extractFailed(L10n.t("create.inside"))
        }

        ArchiveEngine.prepareWork()
        onProgress(PackUpdate(file: L10n.t("preparing"), fraction: 0))

        let stats = try await Task.detached(priority: .utility) {
            try measure(sources)
        }.value
        if ArchiveEngine.isCancelled {
            throw ArchiveError.cancelled
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        removeProducts(at: destination)

        let sameParent = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL.path }).count == 1
        let staging: URL?
        let inputs: [URL]
        let workDirectory: URL
        if sameParent {
            staging = nil
            inputs = sources
            workDirectory = sources[0].deletingLastPathComponent()
        } else {
            let temp = try await Task.detached(priority: .utility) {
                try stage(sources)
            }.value
            staging = temp
            inputs = sources.map { temp.appendingPathComponent($0.lastPathComponent) }
            workDirectory = temp
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        let meter = PackMeter(bytesTotal: stats.bytes, file: destination.lastPathComponent)

        let poll = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                onProgress(meter.noteBytes(packedBytes(at: destination)))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        defer { poll.cancel() }

        do {
            let volume: String? = {
                guard format.supportsSplit, let volumeBytes, volumeBytes > 0 else { return nil }
                return "\(volumeBytes)b"
            }()
            switch format {
            case .zip:
                if volume != nil {
                    try await sevenZip(inputs, to: destination, directory: workDirectory, type: "zip", volume: volume, meter: meter, onProgress: onProgress)
                } else {
                    try await zip(inputs, to: destination, directory: workDirectory, filesTotal: stats.files, meter: meter, onProgress: onProgress)
                }
            case .sevenZip:
                try await sevenZip(inputs, to: destination, directory: workDirectory, type: "7z", volume: volume, meter: meter, onProgress: onProgress)
            case .rar:
                try await rar(inputs, to: destination, directory: workDirectory, volume: volume, filesTotal: stats.files, meter: meter, onProgress: onProgress)
            case .tar, .tarGz, .tarBz2, .tarXz:
                try await tar(inputs, to: destination, directory: workDirectory, format: format, filesTotal: stats.files, meter: meter, onProgress: onProgress)
            }
        } catch {
            removeProducts(at: destination)
            throw error
        }

        onProgress(PackUpdate(
            file: destination.lastPathComponent,
            fraction: 1,
            bytesDone: packedBytes(at: destination),
            bytesTotal: stats.bytes
        ))
    }

    private static func zip(
        _ urls: [URL],
        to destination: URL,
        directory: URL,
        filesTotal: Int,
        meter: PackMeter,
        onProgress: @escaping @Sendable (PackUpdate) -> Void
    ) async throws {
        var arguments = ["-r", "-X", "-y", destination.path]
        arguments.append(contentsOf: urls.map(\.lastPathComponent))
        arguments.append("-x")
        arguments.append(contentsOf: MacJunk.zipExcludes)
        try await run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: arguments,
            directory: directory
        ) { line in
            guard line.contains("adding:") || line.contains("updating:") else { return }
            onProgress(meter.advance(name: zipAddedName(line), filesTotal: filesTotal))
        }
    }

    private static func sevenZip(
        _ urls: [URL],
        to destination: URL,
        directory: URL,
        type: String,
        volume: String?,
        meter: PackMeter,
        onProgress: @escaping @Sendable (PackUpdate) -> Void
    ) async throws {
        guard let seven = ArchiveEngine.helperURL(named: "7zz") else {
            throw ArchiveError.helperMissing
        }
        var arguments = ["a", "-t\(type)", "-y", "-bso1", "-bsp1"]
        if let volume {
            arguments.append("-v\(volume)")
        }
        arguments.append(destination.path)
        arguments.append(contentsOf: MacJunk.sevenZipExcludes)
        arguments.append(contentsOf: urls.map(\.lastPathComponent))
        try await run(executable: seven, arguments: arguments, directory: directory) { line in
            let cleaned = cleanLine(line)
            if let percent = trailingPercent(cleaned) {
                let onlyPercent = cleaned.range(of: #"^\d+\s*%$"#, options: .regularExpression) != nil
                onProgress(meter.noteOverall(name: onlyPercent ? "" : cleaned, fraction: percent))
            } else if !cleaned.isEmpty, cleaned.count < 180, !cleaned.hasPrefix("7-Zip") {
                onProgress(meter.noteOverall(name: cleaned, fraction: 0))
            }
        }
    }

    private static func rar(
        _ urls: [URL],
        to destination: URL,
        directory: URL,
        volume: String?,
        filesTotal: Int,
        meter: PackMeter,
        onProgress: @escaping @Sendable (PackUpdate) -> Void
    ) async throws {
        guard let rar = rarExecutable() else {
            throw ArchiveError.extractFailed(L10n.t("rar.missing"))
        }
        var arguments = ["a", "-y", "-r", "-ma5", "-m2", "-md32m", "-cfg-"]
        if let volume {
            arguments.append("-v\(volume)")
        }
        arguments.append(contentsOf: MacJunk.rarExcludes)
        arguments.append(destination.path)
        arguments.append(contentsOf: urls.map(\.lastPathComponent))
        try await run(executable: rar, arguments: arguments, directory: directory) { line in
            let cleaned = cleanLine(line)
            guard !cleaned.isEmpty else { return }
            let lower = cleaned.lowercased()
            if lower.hasPrefix("evaluation") || lower.hasPrefix("trial") || lower.hasPrefix("rar ") || lower == "done" || lower.hasPrefix("creating archive") {
                return
            }
            let finished = lower.range(of: #"\bok\b"#, options: .regularExpression) != nil
            guard lower.hasPrefix("adding") || lower.hasPrefix("updating") || trailingPercent(cleaned) != nil || finished else { return }
            onProgress(meter.noteFile(
                name: packEntryName(cleaned),
                fileFraction: finished ? nil : trailingPercent(cleaned),
                finished: finished,
                filesTotal: filesTotal
            ))
        }
    }

    private static func tar(
        _ urls: [URL],
        to destination: URL,
        directory: URL,
        format: CreateFormat,
        filesTotal: Int,
        meter: PackMeter,
        onProgress: @escaping @Sendable (PackUpdate) -> Void
    ) async throws {
        let flag: String
        switch format {
        case .tar: flag = "-cvf"
        case .tarGz: flag = "-czvf"
        case .tarBz2: flag = "-cjvf"
        case .tarXz: flag = "-cJvf"
        default: flag = "-cvf"
        }
        var arguments = MacJunk.tarExcludes
        arguments.append(flag)
        arguments.append(destination.path)
        arguments.append("-C")
        arguments.append(directory.path)
        arguments.append(contentsOf: urls.map(\.lastPathComponent))
        try await run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: arguments,
            directory: directory
        ) { line in
            let name = (line as NSString).lastPathComponent
            guard !name.isEmpty, !name.hasPrefix("a ") else { return }
            onProgress(meter.noteFile(name: name, fileFraction: nil, finished: true, filesTotal: filesTotal))
        }
    }

    private final class OutputTap: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var remainder = ""
        private var lastLive = Date.distantPast

        func push(_ data: Data) -> (finished: [String], live: String?) {
            lock.lock()
            defer { lock.unlock() }
            pending.append(data)
            guard let text = String(data: pending, encoding: .utf8) else {
                if pending.count < 16 { return ([], nil) }
                pending.removeAll(keepingCapacity: true)
                return ([], nil)
            }
            pending.removeAll(keepingCapacity: true)
            return take(text)
        }

        func finish(_ tail: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            var extra = ""
            if !tail.isEmpty, let text = String(data: pending + tail, encoding: .utf8) ?? String(data: tail, encoding: .utf8) {
                extra = text
            } else if let text = String(data: pending, encoding: .utf8) {
                extra = text
            }
            pending.removeAll()
            let combined = remainder + extra.replacingOccurrences(of: "\r", with: "\n")
            remainder = ""
            return combined.components(separatedBy: "\n").map { cleanLine($0) }.filter { !$0.isEmpty }
        }

        private func take(_ text: String) -> (finished: [String], live: String?) {
            remainder += text.replacingOccurrences(of: "\r", with: "\n")
            let parts = remainder.components(separatedBy: "\n")
            remainder = parts.last ?? ""
            let finished = parts.dropLast().map { cleanLine($0) }.filter { !$0.isEmpty }
            let live = cleanLine(remainder)
            let now = Date()
            let emitLive = !live.isEmpty && now.timeIntervalSince(lastLive) >= 0.12
            if emitLive { lastLive = now }
            return (Array(finished), emitLive ? live : nil)
        }
    }

    private static func run(
        executable: URL,
        arguments: [String],
        directory: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ArchiveError.helperMissing
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = packEnvironment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                let handle = pipe.fileHandleForReading
                let tap = OutputTap()
                handle.readabilityHandler = { file in
                    let data = file.availableData
                    guard !data.isEmpty else { return }
                    let lines = tap.push(data)
                    for line in lines.finished { onLine(line) }
                    if let live = lines.live { onLine(live) }
                }
                do {
                    try ArchiveEngine.adopt(process)
                    try process.run()
                    process.waitUntilExit()
                    handle.readabilityHandler = nil
                    for line in tap.finish(handle.readDataToEndOfFile()) {
                        onLine(line)
                    }
                    ArchiveEngine.release(process)
                    if ArchiveEngine.isCancelled || process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ArchiveError.cancelled)
                        return
                    }
                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ArchiveError.extractFailed(L10n.t("create.failed")))
                        return
                    }
                    continuation.resume()
                } catch {
                    handle.readabilityHandler = nil
                    if ArchiveEngine.isCancelled {
                        continuation.resume(throwing: ArchiveError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func measure(_ urls: [URL]) throws -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for url in urls {
            if ArchiveEngine.isCancelled { throw ArchiveError.cancelled }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                files += 1
                bytes += fileSize(url)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator {
                if files % 200 == 0, ArchiveEngine.isCancelled { throw ArchiveError.cancelled }
                if MacJunk.isJunk(file.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values?.isRegularFile == true {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (files, bytes)
    }

    private static func stage(_ urls: [URL]) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnarchivePack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for url in urls {
            if ArchiveEngine.isCancelled { throw ArchiveError.cancelled }
            let target = temp.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
        }
        return temp
    }

    private static func destinationIsInside(_ source: URL, destination: URL) -> Bool {
        let sourcePath = source.standardizedFileURL.path
        let destPath = destination.standardizedFileURL.path
        return destPath == sourcePath || destPath.hasPrefix(sourcePath + "/")
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func packedBytes(at destination: URL) -> Int64 {
        producedFiles(at: destination).reduce(Int64(0)) { $0 + fileSize($1) }
    }

    private static func removeProducts(at destination: URL) {
        for file in producedFiles(at: destination) {
            try? FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    private static func cleanLine(_ raw: String) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(raw.count)
        for character in raw {
            if character == "\u{08}" {
                if !chars.isEmpty { chars.removeLast() }
            } else if character != "\r" {
                chars.append(character)
            }
        }
        return String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func suggestedName(for urls: [URL], format: CreateFormat) -> String {
        let base: String
        if urls.count == 1 {
            base = archiveBaseName(urls[0].lastPathComponent, format: format)
            if base.isEmpty {
                return "Archive.\(format.fileExtension)"
            }
        } else {
            base = "Archive"
        }
        return "\(base).\(format.fileExtension)"
    }

    private static func archiveBaseName(_ name: String, format: CreateFormat) -> String {
        let suffix = ".\(format.fileExtension)"
        if name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    private static func zipAddedName(_ line: String) -> String {
        guard let range = line.range(of: "adding:") ?? line.range(of: "updating:") else {
            return line
        }
        var name = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if let paren = name.lastIndex(of: "(") {
            name = name[..<paren].trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    private static func packEntryName(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("adding") {
            text = String(text.dropFirst("adding".count))
        } else if lower.hasPrefix("updating") {
            text = String(text.dropFirst("updating".count))
        }
        if let range = text.range(of: #"\s+(\d+\s*%|OK)\s*$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trailingPercent(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*%"#) else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, range: range),
              let inner = Range(match.range(at: 1), in: line),
              let value = Double(line[inner]) else {
            return nil
        }
        return min(max(value / 100, 0), 0.99)
    }

    private static let packEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "COPYFILE_DISABLE": "1",
        "COPY_EXTENDED_ATTRIBUTES_DISABLE": "1"
    ]
}

enum MacJunk {
    static func isJunk(_ name: String) -> Bool {
        if name == ".DS_Store" || name == ".AppleDouble" || name == ".AppleDB" || name == ".AppleDesktop" {
            return true
        }
        if name == "__MACOSX" || name == ".Spotlight-V100" || name == ".Trashes" || name == ".fseventsd" || name == ".TemporaryItems" {
            return true
        }
        return name.hasPrefix("._")
    }

    static let zipExcludes = [
        "*.DS_Store", "*/.DS_Store",
        "._*", "*/._*",
        "__MACOSX", "__MACOSX/*", "*/__MACOSX", "*/__MACOSX/*",
        ".AppleDouble", ".AppleDouble/*", "*/.AppleDouble", "*/.AppleDouble/*",
        ".AppleDB", ".AppleDB/*", "*/.AppleDB", "*/.AppleDB/*",
        ".Spotlight-V100", ".Spotlight-V100/*", "*/.Spotlight-V100", "*/.Spotlight-V100/*",
        ".Trashes", ".Trashes/*", "*/.Trashes", "*/.Trashes/*",
        ".fseventsd", ".fseventsd/*", "*/.fseventsd", "*/.fseventsd/*",
        ".TemporaryItems", ".TemporaryItems/*", "*/.TemporaryItems", "*/.TemporaryItems/*"
    ]

    static let rarExcludes = [
        "-x*.DS_Store",
        "-x*/.DS_Store",
        "-x._*",
        "-x*._*",
        "-x*/._*",
        "-x__MACOSX/",
        "-x*/__MACOSX/",
        "-x.AppleDouble/",
        "-x*/.AppleDouble/",
        "-x.AppleDB/",
        "-x.Spotlight-V100/",
        "-x.Trashes/",
        "-x.fseventsd/",
        "-x.TemporaryItems/"
    ]

    static let sevenZipExcludes = [
        "-xr!.DS_Store",
        "-xr!._*",
        "-xr!__MACOSX",
        "-xr!.AppleDouble",
        "-xr!.AppleDB",
        "-xr!.Spotlight-V100",
        "-xr!.Trashes",
        "-xr!.fseventsd",
        "-xr!.TemporaryItems"
    ]

    static let tarExcludes = [
        "--exclude=.DS_Store",
        "--exclude=._*",
        "--exclude=__MACOSX",
        "--exclude=.AppleDouble",
        "--exclude=.AppleDB",
        "--exclude=.Spotlight-V100",
        "--exclude=.Trashes",
        "--exclude=.fseventsd",
        "--exclude=.TemporaryItems"
    ]
}
