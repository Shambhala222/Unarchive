import AppKit
import SwiftUI

struct CreateArchiveSheet: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.t("create.archive"))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("create.sources").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(sourceSummary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("column.name").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("column.name"), text: $state.createName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("create.where").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(state.createFolder?.path ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(L10n.t("create.pickfolder")) {
                        chooseFolder()
                    }
                    .pointingHand()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("default.format").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                EvenWrap(spacing: 8) {
                    ForEach(CreateFormat.allCases) { format in
                        formatButton(format)
                    }
                }
                if state.createFormat == .rar, !ArchiveCreator.rarAvailable {
                    Text(L10n.t("rar.missing"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if state.createFormat == .rar {
                    Text(L10n.t("rar.level"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("split.title").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                EvenWrap(spacing: 8) {
                    choiceButton(L10n.t("split.none"), selected: !state.createParts, enabled: true) {
                        state.createParts = false
                    }
                    choiceButton(L10n.t("split.several"), selected: state.createParts, enabled: state.createFormat.supportsSplit) {
                        state.createParts = true
                    }
                }
                if state.createFormat.supportsSplit, state.createParts {
                    HStack(spacing: 8) {
                        Text(L10n.t("split.size"))
                            .foregroundStyle(.secondary)
                        TextField("100", text: $state.createPartAmount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Picker(L10n.t("split.size"), selection: $state.createPartUnit) {
                            ForEach(PartUnit.allCases) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                        .pointingHand()
                    }
                    Text(L10n.t("split.binary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.resolvedPartBytes != nil {
                        Text(L10n.t("split.example", partExample))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !state.createFormat.supportsSplit {
                    Text(L10n.t("split.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if fileExists {
                Text(L10n.t("create.replace"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(L10n.t("cancel")) {
                    state.showCreateSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .pointingHand()
                Button(L10n.t("create")) {
                    state.commitCreate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .pointingHand()
            }
        }
        .padding(24)
        .frame(width: 680)
        .onChange(of: state.createFormat) { _, newFormat in
            state.createName = ArchiveCreator.name(keepingBaseOf: state.createName, format: newFormat)
            if !newFormat.supportsSplit {
                state.createParts = false
            }
        }
    }

    private var canCreate: Bool {
        let name = state.createName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, state.createFolder != nil, !state.createSources.isEmpty else { return false }
        if state.createFormat == .rar, !ArchiveCreator.rarAvailable { return false }
        if state.createFormat.supportsSplit, state.createParts, state.resolvedPartBytes == nil { return false }
        return true
    }

    private var fileExists: Bool {
        guard let folder = state.createFolder else { return false }
        let name = state.createName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private var sourceSummary: String {
        let urls = state.createSources
        if urls.isEmpty { return "—" }
        if urls.count == 1 { return urls[0].lastPathComponent }
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        if urls.count > 3 {
            return "\(names) +\(urls.count - 3)"
        }
        return names
    }

    private var partExample: String {
        let base = ArchiveCreator.name(keepingBaseOf: state.createName, format: state.createFormat)
        let stem = (base as NSString).deletingPathExtension
        switch state.createFormat {
        case .rar:
            return "\(stem).part1.rar"
        case .zip:
            return "\(stem).zip.001"
        case .sevenZip:
            return "\(stem).7z.001"
        default:
            return base
        }
    }

    private func formatButton(_ format: CreateFormat) -> some View {
        choiceButton(format.title, selected: state.createFormat == format, enabled: true) {
            state.createFormat = format
        }
    }

    private func choiceButton(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(enabled ? 0.06 : 0.03),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointingHand()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("create.where")
        panel.prompt = L10n.t("create.pickfolder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.createFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.createFolder = url
    }
}

struct EvenWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 680
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        var index = 0
        for row in rows {
            var x = bounds.minX
            for size in row.sizes {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [(height: CGFloat, sizes: [CGSize])] {
        var rows: [(height: CGFloat, sizes: [CGSize])] = []
        var current: [CGSize] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let next = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if rowWidth > 0, next > maxWidth {
                rows.append((rowHeight, current))
                current = [size]
                rowWidth = size.width
                rowHeight = size.height
            } else {
                current.append(size)
                rowWidth = next
                rowHeight = max(rowHeight, size.height)
            }
        }
        if !current.isEmpty {
            rows.append((rowHeight, current))
        }
        return rows
    }
}
