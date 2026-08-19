import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.t("general"), systemImage: "gearshape") }
            extraction
                .tabItem { Label(L10n.t("extraction"), systemImage: "tray.and.arrow.down") }
            passwords
                .tabItem { Label(L10n.t("password.archive"), systemImage: "key.fill") }
            creating
                .tabItem { Label(L10n.t("creating"), systemImage: "plus.square.on.square") }
            about
                .tabItem { Label(L10n.t("about"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 560)
        .id(settings.revision)
    }

    private var general: some View {
        Form {
            Picker(L10n.t("language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .onChange(of: settings.language) { _, _ in settings.bump() }

            Picker(L10n.t("appearance"), selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }

            Button(L10n.t("set.default")) {
                NotificationCenter.default.post(name: .unarchiveBecomeDefault, object: nil)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var extraction: some View {
        Form {
            Toggle(L10n.t("reveal.after"), isOn: $settings.revealAfterExtract)
            LabeledContent(L10n.t("formats.unpack")) {
                Text(SupportedArchives.unpackSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var passwords: some View {
        PasswordArchiveView(settings: settings)
    }

    private var creating: some View {
        Form {
            Picker(L10n.t("default.format"), selection: $settings.defaultCreateFormat) {
                ForEach(CreateFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Text(L10n.t("pack.note"))
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var about: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Unarchive")
                .font(.title2.weight(.semibold))
            Text(L10n.t("version", settings.appVersion, settings.buildNumber))
                .foregroundStyle(.secondary)
            Text(L10n.t("about.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            VStack(spacing: 4) {
                Text(L10n.t("credits"))
                    .font(.headline)
                Text(L10n.t("engine"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("legal"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            Text(L10n.t("copyright"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    static let unarchiveBecomeDefault = Notification.Name("unarchiveBecomeDefault")
}

private struct PasswordArchiveView: View {
    @Bindable var settings: SettingsStore
    @State private var saved: [String] = []
    @State private var newPassword = ""
    @State private var revealed: Set<String> = []

    var body: some View {
        Form {
            Toggle(L10n.t("password.remember"), isOn: $settings.rememberPasswords)
            Text(L10n.t("password.remember.help"))
                .foregroundStyle(.secondary)
                .font(.callout)

            Section {
                HStack {
                    SecureField(L10n.t("password.enter"), text: $newPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addPassword() }
                    Button(L10n.t("password.add")) { addPassword() }
                        .disabled(newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text(L10n.t("password.teach"))
            } footer: {
                Text(L10n.t("password.teach.help"))
            }

            Section {
                if saved.isEmpty {
                    Text(L10n.t("password.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(saved, id: \.self) { item in
                        HStack(spacing: 8) {
                            if revealed.contains(item) {
                                Text(item)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            } else {
                                Text(String(repeating: "•", count: min(max(item.count, 6), 18)))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                if revealed.contains(item) {
                                    revealed.remove(item)
                                } else {
                                    revealed.insert(item)
                                }
                            } label: {
                                Image(systemName: revealed.contains(item) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(revealed.contains(item) ? L10n.t("password.hide") : L10n.t("password.show"))

                            Button(role: .destructive) {
                                PasswordVault.remove(item)
                                revealed.remove(item)
                                reload()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("password.delete"))
                        }
                    }
                    Button(L10n.t("password.clear"), role: .destructive) {
                        PasswordVault.clear()
                        revealed.removeAll()
                        reload()
                    }
                }
            } header: {
                Text(L10n.t("password.saved.count", saved.count))
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: reload)
    }

    private func addPassword() {
        let value = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        PasswordVault.remember(value)
        newPassword = ""
        reload()
    }

    private func reload() {
        saved = PasswordVault.recent()
    }
}
