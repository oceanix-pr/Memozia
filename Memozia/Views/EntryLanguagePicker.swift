import SwiftUI

/// One editor per entry. A failed read or write is visible and leaves the previous choices intact.
struct EntryLanguagePicker: View {
    let fileURL: URL
    var transcription: STTConfig?
    var readOnly: Bool
    @State private var options = EntryLanguageOptions()
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let transcription {
                let effective = options.applying(to: transcription)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("转写语言", selection: binding(\.spoken)) {
                        let inherited = WhisperLanguage(rawValue: transcription.language) ?? .auto
                        let inheritedName = inherited == .auto && effective.mode == .system ? String(localized: "跟随系统") : inherited.displayName
                        Text("跟随设置（\(inheritedName)）").tag(nil as WhisperLanguage?)
                        ForEach(WhisperLanguage.allCases) { language in
                            Text(language == .auto && effective.mode == .system ? String(localized: "跟随系统") : language.displayName)
                                .tag(Optional(language))
                        }
                    }
                    .accessibilityIdentifier("entrySpokenLanguage")
                    if effective.isChineseSpeech {
                        let inherited = EntryLanguageOptions(spoken: options.spoken).applying(to: transcription).effectiveScript
                        Picker("中文字形", selection: binding(\.script)) {
                            Text("跟随设置（\(inherited.name)）").tag(nil as TranscriptScript?)
                            ForEach(TranscriptScript.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                        }
                    }
                }
            } else {
                Picker("纪要语言", selection: binding(\.output)) {
                    Text("跟随原文").tag("")
                    ForEach(ContentLanguages.choices, id: \.code) { Text($0.nativeName).tag($0.code) }
                }
                .accessibilityIdentifier("entrySummaryLanguage")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .disabled(readOnly || !loaded)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onChange(of: fileURL, initial: true) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: EntryLanguageOptions.didChange)) { change in
            guard change.object as? URL == fileURL else { return }
            reload()
        }
    }

    private func reload() {
        do {
            options = try EntryLanguageOptions.load(from: fileURL)
            loaded = true
            error = nil
        } catch {
            loaded = false
            self.error = error.localizedDescription
        }
    }

    private func binding<T>(_ key: WritableKeyPath<EntryLanguageOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: key] }, set: { write(key, $0) })
    }

    private func write<T>(_ key: WritableKeyPath<EntryLanguageOptions, T>, _ value: T) {
        guard !readOnly, loaded else { return }
        do {
            options = try EntryLanguageOptions.update(at: fileURL) { $0[keyPath: key] = value }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

extension LayoutDirection {
    /// macOS 可以单独切换应用语言。按本次启动实际载入的资源设置阅读方向。
    @MainActor static let interfaceLanguageDirection: LayoutDirection = {
        if UserDefaults.standard.bool(forKey: "NSForceRightToLeft") { return .rightToLeft }
        let selected = UserDefaults.standard.string(forKey: MenuBarController.appLanguageDefaultsKey) ?? ""
        let language = selected.isEmpty ? (Bundle.main.preferredLocalizations.first ?? Locale.current.identifier) : selected
        return Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }()
}

struct InterfaceLanguagePicker: View {
    @AppStorage(MenuBarController.appLanguageDefaultsKey) private var language = ""

    var body: some View {
        Picker(selection: Binding(get: { language }, set: MenuBarController.applyInterfaceLanguage)) {
            Text("跟随系统").tag("")
            ForEach(ContentLanguages.choices, id: \.code) { Text($0.nativeName).tag($0.code) }
        } label: {
            Label("界面语言", systemImage: "globe")
        }
        .accessibilityIdentifier("interfaceLanguage")
    }
}
