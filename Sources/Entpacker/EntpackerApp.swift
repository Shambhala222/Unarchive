import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NotificationCenter.default.addObserver(
            forName: .unarchiveBecomeDefault,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.state?.becomeDefaultHandler()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let state else { return }
        Task { @MainActor in
            for url in urls where SupportedArchives.isArchive(url) {
                await state.open(url)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard let state else { return false }
        Task { @MainActor in await state.open(url) }
        return true
    }

    @objc func openArchives(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleService(pboard, mode: .open)
    }

    @objc func extractHere(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleService(pboard, mode: .extractHere)
    }

    @objc func extractIntoFolder(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleService(pboard, mode: .extractFolder)
    }

    @objc func extractTo(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleService(pboard, mode: .extractChoose)
    }

    @objc func zipItems(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            ArchiveCreator.createNextTo(urls, format: SettingsStore.shared.defaultCreateFormat)
        }
    }

    private enum ServiceMode {
        case open, extractHere, extractFolder, extractChoose
    }

    private func handleService(_ pboard: NSPasteboard, mode: ServiceMode) {
        let urls = fileURLs(from: pboard).filter(SupportedArchives.isArchive)
        guard let state, let first = urls.first else { return }
        Task { @MainActor in
            switch mode {
            case .open:
                await state.open(first)
                NSApp.activate(ignoringOtherApps: true)
            case .extractHere:
                await state.extract(archive: first, mode: .here)
            case .extractFolder:
                await state.extract(archive: first, mode: .intoFolder)
            case .extractChoose:
                await state.extract(archive: first, mode: .choose)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls
        }
        if let filenames = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}

@main
struct UnarchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @State private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .onAppear { appDelegate.state = state }
                .onOpenURL { url in
                    Task { await state.open(url) }
                }
        }
        .defaultSize(width: 1020, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(L10n.t("about")) Unarchive") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "\(L10n.t("credits"))\n\n\(L10n.t("about.body"))\n\n\(L10n.t("engine"))\n\(L10n.t("legal"))",
                            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
                        ),
                        .applicationName: "Unarchive",
                        .version: SettingsStore.shared.appVersion
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("open.archive")) {
                    state.openArchive()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(L10n.t("create.archive")) {
                    state.createArchive()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button(L10n.t("set.default")) {
                    state.becomeDefaultHandler()
                }
                Divider()
                Button(L10n.t("extract.to")) {
                    state.extractSelected(to: nil, createFolder: nil, reveal: settings.revealAfterExtract)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!state.hasArchive || state.isExtracting)

                Button(L10n.t("extract.here")) {
                    state.extractHere(createFolder: false)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.hasArchive || state.isExtracting)

                Button(L10n.t("extract.folder")) {
                    state.extractHere(createFolder: true)
                }
                .disabled(!state.hasArchive || state.isExtracting)

                Button(L10n.t("test")) {
                    state.testArchive()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!state.hasArchive)
            }

            CommandMenu(L10n.t("selection")) {
                Button(L10n.t("open.selection")) {
                    state.openSelection()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.selected.isEmpty)

                Button(L10n.t("extract.to")) {
                    state.extractSelected(to: nil, createFolder: false, reveal: settings.revealAfterExtract)
                }
                .disabled(state.selected.isEmpty)
            }
        }

        Settings {
            SettingsView(settings: settings)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
