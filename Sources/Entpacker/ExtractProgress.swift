import Foundation

struct ExtractProgress: Sendable, Equatable {
    var fraction: Double = 0
    var isDeterminate: Bool = false
    var currentFile: String = ""
    var destination: String = ""
    var archiveName: String = ""
    var volume: String = ""
    var statusLine: String = ""
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var elapsed: TimeInterval = 0
    var eta: TimeInterval?

    static let idle = ExtractProgress()

    var percentText: String {
        guard isDeterminate else { return "" }
        return "\(Int((fraction * 100).rounded())) %"
    }
}

final class ExtractProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var progress = ExtractProgress()
    private var lastEmit = Date.distantPast
    private let minInterval: TimeInterval = 0.12
    private var startedNames: [String] = []

    init(archiveName: String, destination: String, bytesTotal: Int64, filesTotal: Int, sizes: [String: Int64]) {
        _ = sizes
        progress.archiveName = archiveName
        progress.destination = destination
        progress.bytesTotal = bytesTotal
        progress.filesTotal = filesTotal
        progress.isDeterminate = bytesTotal > 0 || filesTotal > 0
        progress.statusLine = L10n.t("extracting")
    }

    func snapshot() -> ExtractProgress {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked(force: true)
    }

    func ingest(_ raw: String) -> ExtractProgress? {
        let line = Self.sanitize(raw)
        guard !line.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if line.lowercased().hasPrefix("extracting from ") {
            progress.volume = String(line.dropFirst("extracting from ".count)).trimmingCharacters(in: .whitespaces)
            progress.statusLine = L10n.t("progress.volume", (progress.volume as NSString).lastPathComponent)
        } else if line.compare("all ok", options: .caseInsensitive) == .orderedSame {
            progress.currentFile = ""
            progress.filesDone = max(progress.filesDone, progress.filesTotal)
            progress.statusLine = L10n.t("progress.finishing")
        } else if Self.isDirectoryLine(line) {
            // Folders are not archive files; ignore them for the file counter.
        } else if let parsed = Self.parseExtractLine(line) {
            noteExtractedFile(parsed.name)
        } else if line.count < 180, !line.contains("%") {
            progress.statusLine = line
        }

        progress.elapsed = Date().timeIntervalSince(startedAt)
        if Date().timeIntervalSince(lastEmit) < minInterval {
            return nil
        }
        lastEmit = Date()
        return progress
    }

    func finished() -> ExtractProgress {
        lock.lock()
        defer { lock.unlock() }
        if progress.bytesTotal > 0 {
            progress.bytesDone = progress.bytesTotal
        }
        progress.fraction = 1
        progress.isDeterminate = true
        progress.currentFile = ""
        progress.statusLine = L10n.t("progress.finishing")
        progress.elapsed = Date().timeIntervalSince(startedAt)
        progress.eta = 0
        return progress
    }

    private func currentLocked(force: Bool) -> ExtractProgress {
        progress.elapsed = Date().timeIntervalSince(startedAt)
        if !force, Date().timeIntervalSince(lastEmit) < minInterval {
            return progress
        }
        lastEmit = Date()
        return progress
    }

    private func noteExtractedFile(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "ok" else { return }
        if name != progress.currentFile {
            progress.currentFile = name
            progress.statusLine = name
        }
        if !startedNames.contains(name) {
            startedNames.append(name)
            progress.filesDone = startedNames.count
        }
    }

    private static func isDirectoryLine(_ line: String) -> Bool {
        line.hasPrefix("Creating ") || line.hasPrefix("Creating\t")
    }

    static func sanitize(_ raw: String) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "\u{08}":
                if !chars.isEmpty { chars.removeLast() }
            case "\r":
                chars.removeAll(keepingCapacity: true)
            case "\u{1B}":
                continue
            default:
                if character.isASCII && character.asciiValue == 0 { continue }
                chars.append(character)
            }
        }
        return String(chars)
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseExtractLine(_ line: String) -> (name: String, percent: Double?)? {
        let prefixes = ["Extracting  ", "Extracting ", "...         ", "...       ", "... "]
        var rest: String?
        for prefix in prefixes where line.hasPrefix(prefix) {
            rest = String(line.dropFirst(prefix.count))
            break
        }
        guard var rest else { return nil }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix("OK") {
            rest = rest.dropLast(2).trimmingCharacters(in: .whitespaces)
        }
        let percent = trailingPercent(rest)
        if let percent {
            if let range = rest.range(of: #"\s+\d+%\s*$"#, options: .regularExpression) {
                rest = rest[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            return (rest, percent)
        }
        return (rest, nil)
    }

    private static func trailingPercent(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*%"#) else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.matches(in: line, range: range).last,
              let inner = Range(match.range(at: 1), in: line),
              let value = Double(line[inner]) else {
            return nil
        }
        return min(max(value / 100, 0), 1)
    }
}
