import SwiftUI
import ServiceManagement

/// The Settings window: General + Dictionary tabs.
@available(macOS 26.0, *)
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionarySettingsView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 480, height: 620)
    }
}

/// General tab: a System Settings-style grouped form. Backed by the same
/// UserDefaults keys the Settings singleton reads, so changes apply to the
/// running dictation pipeline immediately.
@available(macOS 26.0, *)
struct GeneralSettingsView: View {
    @AppStorage("holdKey") private var holdKey = HoldKey.fn.rawValue
    @AppStorage("insertMode") private var insertMode = InsertMode.paste.rawValue
    @AppStorage("aiPolish") private var aiPolish = false
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("showLiveText") private var showLiveText = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = Permissions.accessibilityGranted
    @State private var micGranted = Permissions.micStatus == .authorized
    @State private var todayStats: (notes: Int, words: Int) = (0, 0)
    @State private var totalStats: (notes: Int, words: Int) = (0, 0)
    @State private var appBreakdown: [(app: String, notes: Int, words: Int)] = []

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Dictation key", selection: $holdKey) {
                    ForEach(HoldKey.allCases, id: \.rawValue) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                Text("Hold to talk · double-tap to lock hands-free · Esc cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Insert method", selection: $insertMode) {
                    Text("Paste (fast, recommended)").tag(InsertMode.paste.rawValue)
                    Text("Type keystrokes (max compatibility)").tag(InsertMode.type.rawValue)
                }
                Toggle("Show live transcript in the pill", isOn: $showLiveText)
                Toggle("Sounds", isOn: $playSounds)
            }

            Section("Text") {
                Toggle("AI Polish (on-device)", isOn: $aiPolish)
                    .disabled(!AIFormatter.isAvailable)
                if !AIFormatter.isAvailable {
                    Text("Requires Apple Intelligence (System Settings → Apple Intelligence & Siri). The toggle enables itself once available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Restore clipboard after paste", isOn: $restoreClipboard)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        let service = SMAppService.mainApp
                        do {
                            if enable { try service.register() } else { try service.unregister() }
                        } catch {
                            launchAtLogin = service.status == .enabled
                        }
                    }
                permissionRow(name: "Accessibility",
                              granted: accessibilityGranted,
                              help: "Sees the dictation key globally and pastes for you.") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                permissionRow(name: "Microphone",
                              granted: micGranted,
                              help: "Hears you while the dictation key is held.") {
                    if Permissions.micStatus == .notDetermined {
                        Permissions.requestMic { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Activity") {
                LabeledContent("Today", value: "\(todayStats.words) words · \(todayStats.notes) notes")
                LabeledContent("All time", value: "\(totalStats.words) words · \(totalStats.notes) notes")
                Button("Open Transcripts Folder") {
                    NSWorkspace.shared.open(HistoryStore.transcriptsFolder)
                }
            }

            Section("Where your words go") {
                if appBreakdown.isEmpty {
                    Text("Dictate somewhere and your top apps show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appBreakdown, id: \.app) { row in
                        LabeledContent(row.app) {
                            HStack(spacing: 10) {
                                bar(fraction: Double(row.words) / Double(max(appBreakdown.first?.words ?? 1, 1)))
                                Text("\(row.words) words")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    @ViewBuilder
    private func permissionRow(name: String, granted: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: action)
            }
        } label: {
            Text(name)
            Text(help)
        }
    }

    @ViewBuilder
    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(width: 110, height: 6)
    }

    private func reload() {
        accessibilityGranted = Permissions.accessibilityGranted
        micGranted = Permissions.micStatus == .authorized
        launchAtLogin = SMAppService.mainApp.status == .enabled
        todayStats = HistoryStore.shared.todayStats()
        totalStats = HistoryStore.shared.totalStats()
        appBreakdown = HistoryStore.shared.appBreakdown(limit: 6)
    }
}

/// Dictionary tab: vocabulary the speech engine is biased toward, plus
/// find→replace rules applied to the final text.
@available(macOS 26.0, *)
struct DictionarySettingsView: View {
    @State private var vocabulary: [String] = []
    @State private var rules: [PersonalDictionary.Rule] = []
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section {
                ForEach(vocabulary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            PersonalDictionary.shared.removeWord(word)
                            reload()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \"\(word)\"")
                    }
                }
                HStack {
                    TextField("Add a name or word…", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Hinted to the on-device speech engine so names, products, and jargon are recognized correctly. Takes effect on your next dictation.")
            }

            Section {
                ForEach(rules) { rule in
                    HStack {
                        Text(rule.from)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rule.to)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            PersonalDictionary.shared.removeRule(rule)
                            reload()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove rule")
                    }
                }
                HStack {
                    TextField("When it hears…", text: $newFrom)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("write…", text: $newTo)
                        .onSubmit(addRule)
                    Button("Add", action: addRule)
                        .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Applied to the finished text, whole words, any capitalization — for whatever the engine still gets wrong.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func addWord() {
        PersonalDictionary.shared.addWord(newWord)
        newWord = ""
        reload()
    }

    private func addRule() {
        PersonalDictionary.shared.addRule(from: newFrom, to: newTo)
        newFrom = ""
        newTo = ""
        reload()
    }

    private func reload() {
        vocabulary = PersonalDictionary.shared.vocabulary
        rules = PersonalDictionary.shared.replacements
    }
}
