import Darwin
import Foundation

enum ArchiveEngine {
    static func list(_ url: URL, password: String?) async throws -> ArchiveListing {
        ProcessRegistry.reset()
        let archive = firstVolume(for: url)
        if isRAR(archive), helperURL(named: "unrar") != nil {
            return try await listWithUnrar(archive, password: password)
        }
        return try await listWithLsar(archive, password: password)
    }

    static func cancelActive() {
        ProcessRegistry.cancel()
    }

    static func extract(
        archive: URL,
        password: String?,
        indexes: [Int]?,
        paths: [String]? = nil,
        destination: URL,
        createContainingDirectory: Bool?,
        bytesTotal: Int64 = 0,
        filesTotal: Int = 0,
        fileSizes: [String: Int64] = [:],
        onProgress: (@Sendable (ExtractProgress) -> Void)? = nil
    ) async throws {
        ProcessRegistry.reset()
        let archive = firstVolume(for: archive)
        var destination = destination
        if createContainingDirectory == true {
            destination = destination.appendingPathComponent(archiveBaseName(archive), isDirectory: true)
        }
        let tracker = ExtractProgressTracker(
            archiveName: archive.lastPathComponent,
            destination: destination.path,
            bytesTotal: bytesTotal,
            filesTotal: filesTotal,
            sizes: fileSizes
        )
        onProgress?(tracker.snapshot())
        let report: (@Sendable (String) -> Void)? = { chunk in
            if let update = tracker.ingest(chunk) {
                onProgress?(update)
            }
        }

        do {
            if isRAR(archive), helperURL(named: "unrar") != nil {
                try await extractWithUnrar(
                    archive: archive,
                    password: password,
                    paths: paths,
                    destination: destination,
                    createContainingDirectory: false,
                    onProgress: report
                )
            } else if isSevenZip(archive), helperURL(named: "7zz") != nil {
                try await extractWith7zz(
                    archive: archive,
                    password: password,
                    paths: paths,
                    destination: destination,
                    onProgress: report
                )
            } else {
                try await extractWithUnar(
                    archive: archive,
                    password: password,
                    indexes: indexes,
                    destination: destination,
                    createContainingDirectory: createContainingDirectory == true ? false : createContainingDirectory,
                    onProgress: report
                )
            }
            onProgress?(tracker.finished())
        } catch {
            if ProcessRegistry.isCancelled || error is CancellationError {
                throw ArchiveError.cancelled
            }
            throw error
        }
    }

    static func extractForDrop(
        archive: URL,
        password: String?,
        item: ExtractItem,
        destination: URL,
        bytesTotal: Int64 = 0,
        filesTotal: Int = 0,
        fileSizes: [String: Int64] = [:],
        onProgress: (@Sendable (ExtractProgress) -> Void)? = nil
    ) async throws {
        let destDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        try await extract(
            archive: archive,
            password: password,
            indexes: item.indexes.isEmpty ? nil : item.indexes,
            paths: item.fullPath.isEmpty ? nil : [item.fullPath],
            destination: destDir,
            createContainingDirectory: false,
            bytesTotal: bytesTotal,
            filesTotal: filesTotal,
            fileSizes: fileSizes,
            onProgress: onProgress
        )

        try placeExtractedItem(item, from: destDir, onto: destination)
    }

    static func placeExtractedItem(_ item: ExtractItem, from directory: URL, onto promised: URL) throws {
        let source = locateExtractedItem(named: item.name, fullPath: item.fullPath, in: directory)
            ?? directory.appendingPathComponent(item.fullPath.isEmpty ? item.name : item.fullPath)
        let sourceStd = source.standardizedFileURL
        let promisedStd = promised.standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceStd.path) else { return }
        if sourceStd == promisedStd { return }
        if FileManager.default.fileExists(atPath: promisedStd.path) {
            try FileManager.default.removeItem(at: promisedStd)
        }
        try FileManager.default.createDirectory(
            at: promisedStd.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: sourceStd, to: promisedStd)
    }

    static func test(archive: URL, password: String?) async throws -> String {
        ProcessRegistry.reset()
        let archive = firstVolume(for: archive)
        if isRAR(archive), helperURL(named: "unrar") != nil {
            let result = try await run(
                tool: "unrar",
                arguments: ["t", "-idc", unrarPassword(password), archive.path]
            )
            let output = mergedOutput(result)
            if result.status == 11 || isUnrarPasswordProblem(output) {
                throw passwordError(password)
            }
            if result.status != 0 {
                throw ArchiveError.extractFailed(clean(output))
            }
            return output
        }

        let result = try await run(
            tool: "lsar",
            arguments: {
                var args = ["-t"]
                if let password, !password.isEmpty {
                    args.append(contentsOf: ["-p", password])
                }
                args.append(archive.path)
                return args
            }()
        )
        if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
            throw passwordError(password)
        }
        let output = String(data: result.stdout, encoding: .utf8) ?? result.stderr
        if result.status != 0 {
            throw ArchiveError.extractFailed(clean(output))
        }
        return output
    }

    private enum ProcessRegistry {
        private static let lock = NSLock()
        private static var process: Process?
        private static var cancelled = false

        static func reset() {
            lock.lock()
            cancelled = false
            process = nil
            lock.unlock()
        }

        static func attach(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                throw ArchiveError.cancelled
            }
            self.process = process
        }

        static func detach(_ process: Process) {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }

        static func cancel() {
            lock.lock()
            cancelled = true
            process?.terminate()
            lock.unlock()
        }

        static var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    static func helperURL(named name: String) -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: brew.path) {
            return brew
        }
        return nil
    }

    static func firstVolume(for url: URL) -> URL {
        allVolumes(for: url).first ?? url
    }

    static func allVolumes(for url: URL) -> [URL] {
        let filename = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let range = NSRange(location: 0, length: filename.utf16.count)
        guard let regex = try? NSRegularExpression(pattern: #"^(.*)\.part(\d+)\.rar$"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: filename, options: [], range: range),
              match.numberOfRanges >= 3 else {
            return [url]
        }

        let prefix = (filename as NSString).substring(with: match.range(at: 1))
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let parts: [(Int, URL)] = items.compactMap { item in
            let name = item.lastPathComponent
            let itemRange = NSRange(location: 0, length: name.utf16.count)
            guard let found = regex.firstMatch(in: name, options: [], range: itemRange),
                  (name as NSString).substring(with: found.range(at: 1)).caseInsensitiveCompare(prefix) == .orderedSame,
                  let number = Int((name as NSString).substring(with: found.range(at: 2))) else {
                return nil
            }
            return (number, item)
        }
        .sorted { $0.0 < $1.0 }

        let urls = parts.map(\.1)
        return urls.isEmpty ? [url] : urls
    }

    static func archiveBytes(for url: URL) -> Int64 {
        allVolumes(for: url).reduce(Int64(0)) { partial, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            return partial + size
        }
    }

    static func allocatedBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func acceptsPassword(_ url: URL, password: String) async -> Bool {
        let archive = firstVolume(for: url)
        if isRAR(archive), helperURL(named: "unrar") != nil {
            do {
                let result = try await run(
                    tool: "unrar",
                    arguments: ["lt", "-idc", unrarPassword(password), archive.path]
                )
                let output = mergedOutput(result)
                if result.status == 11 || isUnrarPasswordProblem(output) {
                    return false
                }
                return output.contains("Name:")
            } catch {
                return false
            }
        }
        do {
            let result = try await run(
                tool: "lsar",
                arguments: listArguments(archive: archive, password: password)
            )
            if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - RAR via UnRAR

    static func isSevenZip(_ url: URL) -> Bool {
        ["7z", "cb7"].contains(url.pathExtension.lowercased())
    }

    static func isRAR(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["rar", "cbr"].contains(ext) { return true }
        if name.contains(".part") && name.hasSuffix(".rar") { return true }
        if ext.range(of: #"^r\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func listWithUnrar(_ archive: URL, password: String?) async throws -> ArchiveListing {
        let volumes = allVolumes(for: archive)
        let onDisk = archiveBytes(for: archive)
        var merged: [String: ListedEntry] = [:]
        var format = "RAR"
        var encrypted = false
        var lastError = ""

        for volume in volumes {
            let result = try await run(
                tool: "unrar",
                arguments: ["lt", "-idc", unrarPassword(password), volume.path]
            )
            let output = mergedOutput(result)
            if result.status == 11 || isUnrarPasswordProblem(output) {
                throw passwordError(password)
            }
            if let parsed = unrarFormatName(from: output) {
                format = parsed
            }
            if output.lowercased().contains("encrypted") {
                encrypted = true
            }
            let entries = parseUnrarTechnicalList(output)
            if entries.isEmpty {
                lastError = clean(output)
                continue
            }
            for entry in entries {
                if let existing = merged[entry.path] {
                    if entry.size > existing.size || (!entry.isDirectory && existing.isDirectory) {
                        merged[entry.path] = entry
                    }
                } else {
                    merged[entry.path] = entry
                }
            }
        }

        var entries = Array(merged.values)
        if entries.isEmpty {
            if !lastError.isEmpty {
                throw ArchiveError.listingFailed(lastError)
            }
            throw ArchiveError.listingFailed(L10n.t("list.failed"))
        }
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for index in entries.indices {
            entries[index].index = index
        }

        let root = buildTree(from: entries, archiveName: archive.lastPathComponent)
        let files = root.flattenedFiles()
        return ArchiveListing(
            formatName: format,
            root: root,
            fileCount: files.count,
            totalUncompressed: files.reduce(0) { $0 + $1.uncompressedSize },
            encrypted: encrypted || files.contains(where: \.isEncrypted),
            volumeCount: volumes.count,
            archiveBytes: onDisk
        )
    }

    private static func extractWithUnrar(
        archive: URL,
        password: String?,
        paths: [String]?,
        destination: URL,
        createContainingDirectory: Bool?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        var destination = destination
        if createContainingDirectory == true {
            destination = destination.appendingPathComponent(archiveBaseName(archive), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var arguments = ["x", "-y", "-o+", "-idc", unrarPassword(password), archive.path]
        if let paths, !paths.isEmpty {
            arguments.append(contentsOf: paths.map { $0.replacingOccurrences(of: "\\", with: "/") })
        }
        var destPath = destination.path
        if !destPath.hasSuffix("/") {
            destPath += "/"
        }
        arguments.append(destPath)

        let result = try await run(tool: "unrar", arguments: arguments, onProgress: onProgress)
        let output = mergedOutput(result)
        if result.status == 11 || isUnrarPasswordProblem(output) {
            throw passwordError(password)
        }
        if result.status != 0 || output.lowercased().contains("cannot find volume") {
            throw ArchiveError.extractFailed(clean(output))
        }
    }

    private static func extractWith7zz(
        archive: URL,
        password: String?,
        paths: [String]?,
        destination: URL,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Stream to disk. Avoids unar's hidden working copy that can double the free space needed.
        var arguments = ["x", "-y", "-aoa", "-bb1", "-bsp1", "-bse1"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append("-o\(destination.path)")
        arguments.append(archive.path)
        if let paths, !paths.isEmpty {
            arguments.append(contentsOf: paths.map { $0.replacingOccurrences(of: "\\", with: "/") })
        }

        let result = try await run(tool: "7zz", arguments: arguments, onProgress: onProgress)
        let output = mergedOutput(result)
        let lower = output.lowercased()
        if lower.contains("wrong password") || lower.contains("cannot open encrypted") {
            throw passwordError(password)
        }
        if result.status > 1 {
            throw ArchiveError.extractFailed(clean(output))
        }
    }

    private static func unrarPassword(_ password: String?) -> String {
        if let password, !password.isEmpty {
            return "-p\(password)"
        }
        return "-p-"
    }

    private static func isUnrarPasswordProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("incorrect password")
            || lower.contains("wrong password")
            || lower.contains("enter password")
            || lower.contains("read error in the file stdin") {
            return true
        }
        if lower.contains("encrypted header") && !lower.contains("\n        name:") && !lower.contains("name: ") {
            return true
        }
        return false
    }

    private static func unrarFormatName(from text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("details:") {
                let details = trimmed.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if let first = details.split(separator: ",").first {
                    return String(first).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private static func parseUnrarTechnicalList(_ text: String) -> [ListedEntry] {
        var entries: [ListedEntry] = []
        var current: [String: String] = [:]

        func flush() {
            defer { current = [:] }
            guard let name = current["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return
            }
            if name == "." || name == ".." { return }
            let type = (current["Type"] ?? "File").lowercased()
            if type.contains("service") || type.contains("comment") { return }

            let isDirectory = type.contains("dir")
            let flags = (current["Flags"] ?? "").lowercased()
            let packedKey = current["Packed size"] ?? current["Packed Size"] ?? "0"
            entries.append(
                ListedEntry(
                    path: name,
                    isDirectory: isDirectory,
                    size: parseUnrarInt64(current["Size"] ?? ""),
                    packed: parseUnrarInt64(packedKey),
                    modified: Formatters.unrarDate.date(from: String((current["mtime"] ?? current["Modified"] ?? "").prefix(19))),
                    encrypted: flags.contains("encrypted") || flags.contains("password"),
                    compression: current["Compression"] ?? "",
                    index: entries.count
                )
            )
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            if key == "Name" && !current.isEmpty {
                flush()
            }
            current[key] = value
        }
        flush()
        return entries
    }

    private static func parseUnrarInt64(_ text: String) -> Int64 {
        let digits = text.filter(\.isNumber)
        return Int64(digits) ?? 0
    }

    private static func archiveBaseName(_ url: URL) -> String {
        let filename = firstVolume(for: url).lastPathComponent
        if let regex = try? NSRegularExpression(pattern: #"^(.*)\.part\d+\.rar$"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: filename, options: [], range: NSRange(location: 0, length: filename.utf16.count)),
           match.numberOfRanges >= 2 {
            return (filename as NSString).substring(with: match.range(at: 1))
        }
        return (filename as NSString).deletingPathExtension
    }

    // MARK: - Other formats via lsar/unar

    private static func listWithLsar(_ archive: URL, password: String?) async throws -> ArchiveListing {
        let result = try await run(
            tool: "lsar",
            arguments: listArguments(archive: archive, password: password)
        )

        if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
            throw passwordError(password)
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
                throw passwordError(password)
            }
            if result.status != 0 {
                throw ArchiveError.listingFailed(clean(result.stderr))
            }
            throw ArchiveError.listingFailed(L10n.t("invalid.listing"))
        }

        if let errorValue = json["lsarError"], !(errorValue is NSNull) {
            if isPasswordErrorValue(errorValue) {
                throw passwordError(password)
            }
            let message = stringValue(errorValue) ?? "\(errorValue)"
            if !message.isEmpty && message != "0" {
                throw ArchiveError.listingFailed(message)
            }
        }

        let format = (json["lsarFormatName"] as? String) ?? archive.pathExtension.uppercased()
        let contents = json["lsarContents"] as? [[String: Any]] ?? []
        let root = buildTree(from: contents, archiveName: archive.lastPathComponent)

        if root.children.isEmpty, result.status != 0 {
            if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
                throw passwordError(password)
            }
            throw ArchiveError.listingFailed(clean(result.stderr))
        }

        let files = root.flattenedFiles()
        return ArchiveListing(
            formatName: format,
            root: root,
            fileCount: files.count,
            totalUncompressed: files.reduce(0) { $0 + $1.uncompressedSize },
            encrypted: files.contains(where: \.isEncrypted),
            volumeCount: allVolumes(for: archive).count,
            archiveBytes: archiveBytes(for: archive)
        )
    }

    private static func extractWithUnar(
        archive: URL,
        password: String?,
        indexes: [Int]?,
        destination: URL,
        createContainingDirectory: Bool?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        var arguments = [
            "-f",
            "-nq",
            "-o", destination.path
        ]
        if let createContainingDirectory {
            arguments.append(createContainingDirectory ? "-d" : "-D")
        }
        if let password, !password.isEmpty {
            arguments.append(contentsOf: ["-p", password])
        }
        arguments.append(archive.path)
        if let indexes, !indexes.isEmpty {
            arguments.append("-i")
            arguments.append(contentsOf: indexes.map(String.init))
        }

        let result = try await run(tool: "unar", arguments: arguments, onProgress: onProgress)
        if isPasswordProblem(status: result.status, stdout: result.stdout, stderr: result.stderr) {
            throw passwordError(password)
        }
        if result.status != 0 {
            throw ArchiveError.extractFailed(clean(result.stderr.isEmpty ? String(data: result.stdout, encoding: .utf8) ?? "" : result.stderr))
        }
    }

    // MARK: - Private

    private struct ListedEntry {
        var path: String
        var isDirectory: Bool
        var size: Int64
        var packed: Int64
        var modified: Date?
        var encrypted: Bool
        var compression: String
        var index: Int
    }

    private static func listArguments(archive: URL, password: String?) -> [String] {
        var args = ["-j", "-jss"]
        if let password, !password.isEmpty {
            args.append(contentsOf: ["-p", password])
        }
        args.append(firstVolume(for: archive).path)
        return args
    }

    private static func buildTree(from contents: [[String: Any]], archiveName: String) -> ArchiveNode {
        let entries: [ListedEntry] = contents.compactMap { entry in
            if entry["XADIsResourceFork"] as? Bool == true { return nil }
            guard let rawName = stringValue(entry["XADFileName"]), !rawName.isEmpty else { return nil }
            return ListedEntry(
                path: rawName,
                isDirectory: boolValue(entry["XADIsDirectory"]),
                size: int64Value(entry["XADFileSize"]),
                packed: int64Value(entry["XADCompressedSize"]),
                modified: dateValue(entry["XADLastModificationDate"]),
                encrypted: boolValue(entry["XADIsEncrypted"]),
                compression: stringValue(entry["XADCompressionName"]) ?? "",
                index: intValue(entry["XADIndex"]) ?? 0
            )
        }
        return buildTree(from: entries, archiveName: archiveName)
    }

    private static func buildTree(from contents: [ListedEntry], archiveName: String) -> ArchiveNode {
        let root = ArchiveNode(name: archiveName, fullPath: "", isDirectory: true)

        for entry in contents {
            let normalized = entry.path
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if normalized.isEmpty { continue }
            if normalized.hasPrefix("__MACOSX") { continue }
            if (normalized as NSString).lastPathComponent.hasPrefix("._") { continue }
            if (normalized as NSString).lastPathComponent == ".DS_Store" { continue }

            let parts = normalized.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }

            var cursor = root
            for (offset, part) in parts.enumerated() {
                let isLast = offset == parts.count - 1
                let path = parts[0...offset].joined(separator: "/")
                let isDirectory = isLast ? entry.isDirectory : true

                if let existing = cursor.child(named: part) {
                    if isLast, !existing.isDirectory {
                        break
                    }
                    cursor = existing
                    continue
                }

                let node: ArchiveNode
                if isLast && !isDirectory {
                    node = ArchiveNode(
                        name: part,
                        fullPath: path,
                        index: entry.index,
                        isDirectory: false,
                        uncompressedSize: entry.size,
                        compressedSize: entry.packed,
                        modified: entry.modified,
                        isEncrypted: entry.encrypted,
                        compressionName: entry.compression
                    )
                } else {
                    node = ArchiveNode(
                        name: part,
                        fullPath: path,
                        index: isLast ? entry.index : nil,
                        isDirectory: true,
                        uncompressedSize: 0,
                        compressedSize: 0,
                        modified: isLast ? entry.modified : nil,
                        isEncrypted: isLast && entry.encrypted
                    )
                }
                cursor.addChild(node)
                cursor = node
            }
        }

        root.sortRecursively()
        return root
    }

    private static func locateExtractedItem(named name: String, fullPath: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(fullPath)
        if fm.fileExists(atPath: direct.path) { return direct }

        let byName = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: byName.path) { return byName }

        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator {
                if file.lastPathComponent == name {
                    return file
                }
            }
        }
        if let only = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           only.count == 1 {
            return only[0]
        }
        return nil
    }

    private struct CommandResult: Sendable {
        var stdout: Data
        var stderr: String
        var status: Int32
    }

    private static func mergedOutput(_ result: CommandResult) -> String {
        let out = String(data: result.stdout, encoding: .utf8) ?? ""
        if result.stderr.isEmpty { return out }
        if out.isEmpty { return result.stderr }
        return out + "\n" + result.stderr
    }

    private static func run(
        tool: String,
        arguments: [String],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        guard let executable = helperURL(named: tool) else {
            throw ArchiveError.helperMissing
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.environment = [
                        "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                        "LANG": "en_US.UTF-8",
                        "LC_ALL": "en_US.UTF-8"
                    ]

                    let output = NSMutableData()
                    let lock = NSLock()
                    var remainder = ""

                    let emit: (Data) -> Void = { chunk in
                        guard !chunk.isEmpty else { return }
                        lock.lock()
                        output.append(chunk)
                        lock.unlock()
                        guard let onProgress, let text = String(data: chunk, encoding: .utf8) else { return }
                        remainder += text
                        remainder = remainder.replacingOccurrences(of: "\r", with: "\n")
                        let parts = remainder.components(separatedBy: "\n")
                        remainder = parts.last ?? ""
                        for line in parts.dropLast() {
                            let trimmed = ExtractProgressTracker.sanitize(line)
                            if !trimmed.isEmpty {
                                onProgress(trimmed)
                            }
                        }
                        let live = ExtractProgressTracker.sanitize(remainder)
                        if !live.isEmpty {
                            onProgress(live)
                        }
                    }

                    var slaveToClose: FileHandle?
                    var progressSource: FileHandle?
                    if onProgress != nil, let pty = makePty() {
                        process.standardOutput = pty.slave
                        process.standardError = pty.slave
                        process.standardInput = FileHandle.nullDevice
                        slaveToClose = pty.slave
                        progressSource = pty.master
                        pty.master.readabilityHandler = { handle in
                            emit(handle.availableData)
                        }
                    } else {
                        let out = Pipe()
                        let err = Pipe()
                        process.standardOutput = out
                        process.standardError = err
                        process.standardInput = FileHandle.nullDevice
                        progressSource = out.fileHandleForReading
                        out.fileHandleForReading.readabilityHandler = { handle in
                            emit(handle.availableData)
                        }
                        err.fileHandleForReading.readabilityHandler = { handle in
                            emit(handle.availableData)
                        }
                    }

                    try ProcessRegistry.attach(process)
                    try process.run()
                    if let slaveToClose {
                        try? slaveToClose.close()
                    }
                    process.waitUntilExit()
                    progressSource?.readabilityHandler = nil
                    ProcessRegistry.detach(process)

                    lock.lock()
                    let stdout = Data(referencing: output)
                    lock.unlock()

                    if ProcessRegistry.isCancelled {
                        continuation.resume(throwing: ArchiveError.cancelled)
                        return
                    }
                    continuation.resume(returning: CommandResult(stdout: stdout, stderr: "", status: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makePty() -> (master: FileHandle, slave: FileHandle)? {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var term = termios()
        memset(&term, 0, MemoryLayout<termios>.size)
        cfmakeraw(&term)
        guard openpty(&masterFD, &slaveFD, nil, &term, nil) == 0 else {
            return nil
        }
        return (
            FileHandle(fileDescriptor: masterFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        )
    }

    private static func passwordError(_ password: String?) -> ArchiveError {
        (password ?? "").isEmpty ? .passwordRequired : .wrongPassword
    }

    private static func isPasswordProblem(status: Int32, stdout: Data, stderr: String) -> Bool {
        if isPasswordToken(stderr) { return true }
        if let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
           let error = json["lsarError"],
           isPasswordErrorValue(error) {
            return true
        }
        return false
    }

    private static func isPasswordErrorValue(_ value: Any) -> Bool {
        if intValue(value) == 15 { return true }
        if let text = stringValue(value) { return isPasswordToken(text) }
        return false
    }

    private static func isPasswordToken(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("requires a password")
            || lower.contains("incorrect password")
            || lower.contains("wrong password")
            || lower.contains("password is incorrect")
            || lower.contains("enter password")
            || lower.contains("xadpassword")
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "lsar: ", with: "")
            .replacingOccurrences(of: "unar: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return 0
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let text = value as? String {
            return Formatters.lsarDate.date(from: text)
        }
        return nil
    }
}
