import Foundation

struct ArchiveListing {
    var formatName: String
    var root: ArchiveNode
    var fileCount: Int
    var totalUncompressed: Int64
    var encrypted: Bool
    var volumeCount: Int = 1
    var archiveBytes: Int64 = 0
}

enum ArchiveError: LocalizedError {
    case helperMissing
    case passwordRequired
    case wrongPassword
    case listingFailed(String)
    case extractFailed(String)
    case notAnArchive
    case cancelled
    case busy

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return L10n.t("helper.missing")
        case .passwordRequired:
            return L10n.t("password.needed.extract")
        case .wrongPassword:
            return L10n.t("password.wrong")
        case .listingFailed(let message):
            return message.isEmpty ? L10n.t("list.failed") : message
        case .extractFailed(let message):
            return message.isEmpty ? L10n.t("extract.failed") : message
        case .notAnArchive:
            return L10n.t("not.an.archive")
        case .cancelled:
            return L10n.t("extract.cancelled")
        case .busy:
            return L10n.t("extract.busy")
        }
    }
}

final class ArchiveNode: NSObject, Identifiable {
    let id = UUID()
    let name: String
    let fullPath: String
    let index: Int?
    let isDirectory: Bool
    let uncompressedSize: Int64
    let compressedSize: Int64
    let modified: Date?
    let isEncrypted: Bool
    let compressionName: String
    private(set) var children: [ArchiveNode] = []
    weak var parent: ArchiveNode?

    init(
        name: String,
        fullPath: String,
        index: Int? = nil,
        isDirectory: Bool,
        uncompressedSize: Int64 = 0,
        compressedSize: Int64 = 0,
        modified: Date? = nil,
        isEncrypted: Bool = false,
        compressionName: String = ""
    ) {
        self.name = name
        self.fullPath = fullPath
        self.index = index
        self.isDirectory = isDirectory
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.compressionName = compressionName
    }

    var isLeaf: Bool { !isDirectory || children.isEmpty && index != nil && !isDirectory }

    var descendantIndexes: [Int] {
        if let index, !isDirectory {
            return [index]
        }
        var values: [Int] = []
        if let index {
            values.append(index)
        }
        for child in children {
            values.append(contentsOf: child.descendantIndexes)
        }
        return values
    }

    var recursiveUncompressedSize: Int64 {
        if !isDirectory { return uncompressedSize }
        return children.reduce(0) { $0 + $1.recursiveUncompressedSize }
    }

    var fileCount: Int {
        if !isDirectory { return 1 }
        return children.reduce(0) { $0 + $1.fileCount }
    }

    func addChild(_ node: ArchiveNode) {
        node.parent = self
        children.append(node)
    }

    func child(named name: String) -> ArchiveNode? {
        children.first { $0.name == name }
    }

    func sortRecursively() {
        children.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        children.forEach { $0.sortRecursively() }
    }

    func flattenedFiles() -> [ArchiveNode] {
        if !isDirectory { return [self] }
        return children.flatMap { $0.flattenedFiles() }
    }
}

struct ExtractItem: Sendable {
    let name: String
    let fullPath: String
    let indexes: [Int]
    let isDirectory: Bool

    init(_ node: ArchiveNode) {
        name = node.name
        fullPath = node.fullPath
        indexes = node.descendantIndexes
        isDirectory = node.isDirectory
    }
}

enum SupportedArchives {
    static let fileExtensions: Set<String> = [
        "rar", "cbr", "r00", "r01", "r02", "r03",
        "zip", "zipx", "jar", "war", "ear", "apk", "cbz", "epub", "xlsx", "docx", "pptx",
        "7z", "cb7",
        "tar", "tgz", "tbz", "tbz2", "txz", "tlz",
        "gz", "bz2", "xz", "lz", "lzma", "z",
        "iso", "cab", "lha", "lzh",
        "sit", "sitx", "sea",
        "arj", "ace", "alz", "arc", "ar",
        "cpio", "rpm", "deb",
        "001", "part1"
    ]

    static let openableExtensions: Set<String> = {
        var values = fileExtensions
        values.subtract(["xlsx", "docx", "pptx", "epub", "apk"])
        return values
    }()

    static let unpackSummary = "RAR, ZIP, 7z, TAR, GZ, BZ2, XZ, ISO, CAB, LHA, JAR, ARJ, CPIO, RPM, DEB"

    static let unpackChips = ["RAR", "ZIP", "7z", "TAR", "GZ", "BZ2", "XZ", "ISO", "CAB", "LHA"]
    static let packChips = ["ZIP", "7z", "TAR", "TAR.GZ", "TAR.BZ2", "TAR.XZ"]

    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if openableExtensions.contains(ext) { return true }
        let name = url.lastPathComponent.lowercased()
        if name.contains(".tar.") { return true }
        if name.contains(".part") && name.hasSuffix(".rar") { return true }
        return false
    }
}
