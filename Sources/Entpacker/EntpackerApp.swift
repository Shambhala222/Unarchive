import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppRuntime {
    static var state: AppState?

    @MainActor
    static func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let mains = NSApp.windows.filter { window in
            guard window.canBecomeMain, window.level == .normal, !window.isSheet else { return false }
            guard window.frame.width > 400, window.frame.height > 200 else { return false }
            let title = window.title.lowercased()
            if title.contains("setting") || title.contains("einstellung") || title.contains("réglage") {
                return false
            }
            return true
        }
        guard !mains.isEmpty else { return }
        let keep = mains.first(where: \.isKeyWindow) ?? mains[0]
        if mains.count > 1 {
            for window in mains where window !== keep {
                window.close()
            }
        }
        keep.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState? { AppRuntime.state }
    var openMainWindow: (() -> Void)?
    private var recentOpens: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        NotificationCenter.default.addObserver(
            forName: .unarchiveBecomeDefault,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state?.becomeDefaultHandler()
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            AppRuntime.focusMainWindow()
            return false
        }
        if let openMainWindow {
            openMainWindow()
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
            openMainWindow?()
        }
        deliver(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        deliver([URL(fileURLWithPath: filename)])
        return true
    }

    private func deliver(_ urls: [URL]) {
        let archives = urls.filter(SupportedArchives.isArchive)
        guard !archives.isEmpty, let state = AppRuntime.state else { return }
        Task { @MainActor in
            AppRuntime.focusMainWindow()
            for url in archives {
                let key = url.standardizedFileURL.path
                if let last = self.recentOpens[key], Date().timeIntervalSince(last) < 1.2 {
                    continue
                }
                self.recentOpens[key] = Date()
                await state.open(url)
            }
            AppRuntime.focusMainWindow()
        }
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
            guard let state = AppRuntime.state else { return }
            self.openMainWindow?()
            AppRuntime.focusMainWindow()
            await state.packNextTo(urls)
        }
    }

    private enum ServiceMode {
        case open, extractHere, extractFolder, extractChoose
    }

    private func handleService(_ pboard: NSPasteboard, mode: ServiceMode) {
        let urls = fileURLs(from: pboard).filter(SupportedArchives.isArchive)
        guard !urls.isEmpty, let state = AppRuntime.state else { return }
        Task { @MainActor in
            self.openMainWindow?()
            AppRuntime.focusMainWindow()
            for url in urls {
                switch mode {
                case .open:
                    await state.open(url)
                case .extractHere:
                    await state.extract(archive: url, mode: .here)
                case .extractFolder:
                    await state.extract(archive: url, mode: .intoFolder)
                case .extractChoose:
                    await state.extract(archive: url, mode: .choose)
                }
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
    @Environment(\.openWindow) private var openWindow
    @State private var state: AppState
    @State private var settings = SettingsStore.shared

    init() {
        let state = AppState()
        AppRuntime.state = state
        _state = State(initialValue: state)
    }

    var body: some Scene {
        Window("Unarchive", id: "main") {
            ContentView()
                .environment(state)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .onAppear {
                    appDelegate.openMainWindow = { [openWindow] in
                        openWindow(id: "main")
                    }
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
                .disabled(!state.hasArchive || state.isBusy)

                Button(L10n.t("extract.here")) {
                    state.extractHere(createFolder: false)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.hasArchive || state.isBusy)

                Button(L10n.t("extract.folder")) {
                    state.extractHere(createFolder: true)
                }
                .disabled(!state.hasArchive || state.isBusy)

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
