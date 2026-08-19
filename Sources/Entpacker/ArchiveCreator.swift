import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ArchiveCreator {
    static func createInteractive(format: CreateFormat) {
        let source = NSOpenPanel()
        source.title = L10n.t("create.choose")
        source.prompt = L10n.t("open")
        source.canChooseFiles = true
        source.canChooseDirectories = true
        source.allowsMultipleSelection = true
        guard source.runModal() == .OK, !source.urls.isEmpty else { return }
        save(from: source.urls, format: format)
    }

    static func createNextTo(_ urls: [URL], format: CreateFormat) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let name = suggestedName(for: urls, format: format)
        var destination = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            if format == .tarGz || format == .tarBz2 || format == .tarXz {
                let base = name.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
                destination = folder.appendingPathComponent("\(base)-\(index).\(format.fileExtension)")
            } else {
                destination = folder.appendingPathComponent("\(stem)-\(index).\(format.fileExtension)")
            }
            index += 1
        }
        do {
            try create(from: urls, to: destination, format: format)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            present(error)
        }
    }

    static func save(from urls: [URL], format: CreateFormat) {
        let panel = NSSavePanel()
        panel.title = L10n.t("create.save")
        panel.nameFieldStringValue = suggestedName(for: urls, format: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        if urls.count == 1 {
            panel.directoryURL = urls[0].deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if !destination.lastPathComponent.lowercased().hasSuffix(format.fileExtension) {
            destination = destination.appendingPathExtension(format.fileExtension)
        }
        do {
            try create(from: urls, to: destination, format: format)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            present(error)
        }
    }

    static func create(from urls: [URL], to destination: URL, format: CreateFormat) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        switch format {
        case .zip:
            try zip(urls, to: destination)
        case .sevenZip:
            try sevenZip(urls, to: destination)
        case .tar, .tarGz, .tarBz2, .tarXz:
            try tar(urls, to: destination, format: format)
        }
    }

    private static func zip(_ urls: [URL], to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        if urls.count == 1 {
            process.arguments = ["-c", "-k", "--keepParent", urls[0].path, destination.path]
            try run(process)
            return
        }
        let temp = stagingDirectory(from: urls)
        defer { try? FileManager.default.removeItem(at: temp) }
        process.currentDirectoryURL = temp
        process.arguments = ["-c", "-k", ".", destination.path]
        try run(process)
    }

    private static func sevenZip(_ urls: [URL], to destination: URL) throws {
        guard let seven = ArchiveEngine.helperURL(named: "7zz") else {
            throw ArchiveError.helperMissing
        }
        let process = Process()
        process.executableURL = seven
        var arguments = ["a", "-t7z", "-y", destination.path]
        arguments.append(contentsOf: urls.map(\.path))
        process.arguments = arguments
        try run(process)
    }

    private static func tar(_ urls: [URL], to destination: URL, format: CreateFormat) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        let flag: String
        switch format {
        case .tar: flag = "-cf"
        case .tarGz: flag = "-czf"
        case .tarBz2: flag = "-cjf"
        case .tarXz: flag = "-cJf"
        default: flag = "-cf"
        }
        if urls.count == 1 {
            process.currentDirectoryURL = urls[0].deletingLastPathComponent()
            process.arguments = [flag, destination.path, urls[0].lastPathComponent]
            try run(process)
            return
        }
        let parent = urls[0].deletingLastPathComponent()
        process.currentDirectoryURL = parent
        var arguments = [flag, destination.path]
        arguments.append(contentsOf: urls.map(\.lastPathComponent))
        process.arguments = arguments
        try run(process)
    }

    private static func stagingDirectory(from urls: [URL]) -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnarchivePack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for url in urls {
            try? FileManager.default.copyItem(at: url, to: temp.appendingPathComponent(url.lastPathComponent))
        }
        return temp
    }

    private static func run(_ process: Process) throws {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ArchiveError.extractFailed(L10n.t("create.failed"))
        }
    }

    private static func suggestedName(for urls: [URL], format: CreateFormat) -> String {
        let base: String
        if urls.count == 1 {
            base = urls[0].deletingPathExtension().lastPathComponent
        } else {
            base = "Archive"
        }
        return "\(base).\(format.fileExtension)"
    }

    private static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("create.failed")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
