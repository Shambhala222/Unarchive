import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveOutlineView: NSViewRepresentable {
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let outline = NSOutlineView()
        outline.style = .inset
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.headerView = NSTableHeaderView()
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.autosaveName = "UnarchiveColumns"
        outline.autosaveTableColumns = true
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 6, height: 4)
        outline.menu = context.coordinator.makeContextMenu()

        outline.addTableColumn(makeColumn("name", title: L10n.t("column.name"), width: 420, min: 160))
        outline.addTableColumn(makeColumn("size", title: L10n.t("column.size"), width: 100, min: 70))
        outline.addTableColumn(makeColumn("packed", title: L10n.t("column.packed"), width: 100, min: 70))
        outline.addTableColumn(makeColumn("date", title: L10n.t("column.date"), width: 160, min: 110))
        outline.outlineTableColumn = outline.tableColumns.first

        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.rebuild()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.state = state
        if let outline = nsView.documentView as? NSOutlineView, outline.tableColumns.count >= 4 {
            outline.tableColumns[0].title = L10n.t("column.name")
            outline.tableColumns[1].title = L10n.t("column.size")
            outline.tableColumns[2].title = L10n.t("column.packed")
            outline.tableColumns[3].title = L10n.t("column.date")
            outline.menu = context.coordinator.makeContextMenu()
        }
        context.coordinator.reloadIfNeeded()
    }

    private func makeColumn(_ id: String, title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.resizingMask = .userResizingMask
        return column
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSFilePromiseProviderDelegate {
        var state: AppState
        weak var outline: NSOutlineView?
        private var root: ArchiveNode?
        private var visibleRoot: ArchiveNode?
        private var filter: String = ""
        init(state: AppState) {
            self.state = state
        }

        func rebuild() {
            root = state.listing?.root
            filter = state.searchText
            visibleRoot = filteredRoot()
            outline?.reloadData()
            if filter.isEmpty {
                outline?.collapseItem(nil, collapseChildren: true)
            } else {
                outline?.expandItem(nil, expandChildren: true)
            }
        }

        func reloadIfNeeded() {
            let newRoot = state.listing?.root
            let newFilter = state.searchText
            if newRoot !== root || newFilter != filter {
                rebuild()
            }
        }

        private func filteredRoot() -> ArchiveNode? {
            guard let root else { return nil }
            let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return root }
            return filterNode(root, query: query)
        }

        private func filterNode(_ node: ArchiveNode, query: String) -> ArchiveNode? {
            if !node.isDirectory {
                return node.name.localizedCaseInsensitiveContains(query) ? node : nil
            }
            let kept = node.children.compactMap { filterNode($0, query: query) }
            if node.name.localizedCaseInsensitiveContains(query) || !kept.isEmpty {
                let copy = ArchiveNode(
                    name: node.name,
                    fullPath: node.fullPath,
                    index: node.index,
                    isDirectory: true,
                    uncompressedSize: node.uncompressedSize,
                    compressedSize: node.compressedSize,
                    modified: node.modified,
                    isEncrypted: node.isEncrypted,
                    compressionName: node.compressionName
                )
                kept.forEach { copy.addChild($0) }
                return copy
            }
            return nil
        }

        private func nodes() -> ArchiveNode {
            visibleRoot ?? state.listing?.root ?? ArchiveNode(name: "", fullPath: "", isDirectory: true)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return nodes().children.count }
            return (item as? ArchiveNode)?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let parent = (item as? ArchiveNode) ?? nodes()
            return parent.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ArchiveNode)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
            guard let node = item as? ArchiveNode else { return nil }
            switch tableColumn?.identifier.rawValue {
            case "name":
                return node.name
            case "size":
                return node.isDirectory ? "—" : Formatters.bytes(node.uncompressedSize)
            case "packed":
                return node.isDirectory ? "—" : Formatters.bytes(node.compressedSize)
            case "date":
                guard let date = node.modified else { return "—" }
                return Formatters.date.string(from: date)
            default:
                return nil
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ArchiveNode, let tableColumn else { return nil }
            let id = tableColumn.identifier
            if id.rawValue == "name" {
                let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                    ?? makeNameCell(identifier: id)
                cell.imageView?.image = icon(for: node)
                cell.textField?.stringValue = node.name
                return cell
            }
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? makeTextCell(identifier: id)
            cell.textField?.stringValue = columnText(for: node, column: id.rawValue)
            cell.textField?.alignment = id.rawValue == "date" ? .left : .right
            return cell
        }

        private func columnText(for node: ArchiveNode, column: String) -> String {
            switch column {
            case "size":
                return node.isDirectory ? "—" : Formatters.bytes(node.uncompressedSize)
            case "packed":
                return node.isDirectory ? "—" : Formatters.bytes(node.compressedSize)
            case "date":
                guard let date = node.modified else { return "—" }
                return Formatters.date.string(from: date)
            default:
                return node.name
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            NSTableRowView()
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            let items: [ArchiveNode] = outline.selectedRowIndexes.compactMap { row in
                outline.item(atRow: row) as? ArchiveNode
            }
            state.selected = items
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard !state.isExtracting else { return nil }
            guard let node = item as? ArchiveNode, let archive = state.archiveURL else { return nil }
            let type = node.isDirectory ? UTType.folder.identifier : (UTType(filenameExtension: (node.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier)
            let provider = NSFilePromiseProvider(fileType: type, delegate: self)
            provider.userInfo = DropContext(entry: ExtractItem(node), archiveURL: archive, password: state.password)
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            let nodes = draggedItems.compactMap { $0 as? ArchiveNode }
            state.beginDragExtract(nodes.isEmpty ? state.selected : nodes)
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? DropContext)?.entry.name ?? "Datei"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let context = filePromiseProvider.userInfo as? DropContext else {
                completionHandler(ArchiveError.extractFailed("Ungültige Drag-Daten."))
                return
            }
            let entry = context.entry
            Task { @MainActor in
                do {
                    try await self.state.fulfillDrop(entry: entry, destination: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            Coordinator.promiseQueue
        }

        private static let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.shambhala222.unarchive.drop"
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline else { return }
            let row = outline.clickedRow
            guard row >= 0, let node = outline.item(atRow: row) as? ArchiveNode else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                } else {
                    outline.expandItem(node)
                }
            } else {
                state.selected = [node]
                state.openSelection()
            }
        }

        @objc func openItems() { state.openSelection() }
        @objc func extractItems() { state.extractSelected(to: nil, createFolder: false, reveal: true) }
        @objc func extractHere() { state.extractHere(createFolder: false) }
        @objc func extractFolder() { state.extractHere(createFolder: true) }
        @objc func copyNames() {
            let names = state.selected.map(\.fullPath).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
        }
        @objc func showInfo() {
            guard let node = state.selected.first else { return }
            let alert = NSAlert()
            alert.messageText = node.name
            var lines: [String] = []
            lines.append("\(L10n.t("path")): \(node.fullPath)")
            if node.isDirectory {
                lines.append("\(L10n.t("type")): \(L10n.t("folder"))")
                lines.append("\(L10n.t("files")): \(node.fileCount)")
                lines.append("\(L10n.t("column.size")): \(Formatters.bytes(node.recursiveUncompressedSize))")
            } else {
                lines.append("\(L10n.t("type")): \(L10n.t("file"))")
                lines.append("\(L10n.t("column.size")): \(Formatters.bytes(node.uncompressedSize))")
                lines.append("\(L10n.t("column.packed")): \(Formatters.bytes(node.compressedSize))")
                if !node.compressionName.isEmpty {
                    lines.append("\(L10n.t("method")): \(node.compressionName)")
                }
            }
            if let date = node.modified {
                lines.append("\(L10n.t("modified")): \(Formatters.date.string(from: date))")
            }
            if node.isEncrypted { lines.append("\(L10n.t("encrypted")): \(L10n.t("yes"))") }
            alert.informativeText = lines.joined(separator: "\n")
            alert.runModal()
        }

        @objc func quickLook() {
            guard let archive = state.archiveURL, let node = state.selected.first else { return }
            Task { @MainActor in
                await state.preview(node, from: archive, open: false)
            }
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: L10n.t("open.selection"), action: #selector(openItems), keyEquivalent: "")
            menu.addItem(withTitle: L10n.t("show.finder"), action: #selector(quickLook), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.t("extract.to"), action: #selector(extractItems), keyEquivalent: "")
            menu.addItem(withTitle: L10n.t("extract.here"), action: #selector(extractHere), keyEquivalent: "")
            menu.addItem(withTitle: L10n.t("extract.folder"), action: #selector(extractFolder), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.t("copy.names"), action: #selector(copyNames), keyEquivalent: "")
            menu.addItem(withTitle: L10n.t("info"), action: #selector(showInfo), keyEquivalent: "")
            for item in menu.items {
                item.target = self
            }
            return menu
        }

        private func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.textColor = .secondaryLabelColor
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func icon(for node: ArchiveNode) -> NSImage {
            if node.isDirectory {
                return NSWorkspace.shared.icon(for: .folder)
            }
            let ext = (node.name as NSString).pathExtension
            if let type = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
    }
}

final class DropContext: NSObject {
    let entry: ExtractItem
    let archiveURL: URL
    let password: String

    init(entry: ExtractItem, archiveURL: URL, password: String) {
        self.entry = entry
        self.archiveURL = archiveURL
        self.password = password
    }
}
