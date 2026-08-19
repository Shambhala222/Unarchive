import Foundation
import SwiftUI

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    static let languageKey = "unarchive.language"
    static let appearanceKey = "unarchive.appearance"
    static let revealKey = "unarchive.revealAfterExtract"
    static let rememberPasswordsKey = "unarchive.rememberPasswords"
    static let formatKey = "unarchive.defaultCreateFormat"
    static let recentsKey = "unarchive.recents"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    var revealAfterExtract: Bool {
        didSet { UserDefaults.standard.set(revealAfterExtract, forKey: Self.revealKey) }
    }
    var rememberPasswords: Bool {
        didSet { UserDefaults.standard.set(rememberPasswords, forKey: Self.rememberPasswordsKey) }
    }
    var defaultCreateFormat: CreateFormat {
        didSet { UserDefaults.standard.set(defaultCreateFormat.rawValue, forKey: Self.formatKey) }
    }
    var recents: [URL]

    var revision: Int = 0

    private init() {
        let defaults = UserDefaults.standard
        language = AppLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        revealAfterExtract = defaults.object(forKey: Self.revealKey) as? Bool ?? true
        rememberPasswords = defaults.object(forKey: Self.rememberPasswordsKey) as? Bool ?? true
        defaultCreateFormat = CreateFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .zip
        recents = (defaults.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func remember(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 8 { recents = Array(recents.prefix(8)) }
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
    }

    func bump() {
        revision += 1
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
    }
}
