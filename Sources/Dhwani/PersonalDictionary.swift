import Foundation

/// The user's personal dictionary, persisted as JSON in Application Support.
/// Two halves:
///  - vocabulary: words/names fed to the speech engine as contextual strings,
///    biasing recognition toward them ("Dhwani", coworker names, jargon)
///  - replacements: find→replace rules applied to the final text, for the
///    cases the engine still gets wrong
/// All access happens on the main thread (settings UI + dictation pipeline).
final class PersonalDictionary {
    static let shared = PersonalDictionary()

    struct Rule: Codable, Equatable, Identifiable {
        var id = UUID()
        var from: String
        var to: String
    }

    private struct Contents: Codable {
        var vocabulary: [String] = []
        var replacements: [Rule] = []
    }

    private(set) var vocabulary: [String] = []
    private(set) var replacements: [Rule] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dhwani", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let contents = try? JSONDecoder().decode(Contents.self, from: data) {
            vocabulary = contents.vocabulary
            replacements = contents.replacements
        } else {
            vocabulary = ["Dhwani"] // seed: the app should spell its own name right
            save()
        }
    }

    // MARK: - Editing

    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        vocabulary.append(trimmed)
        save()
    }

    func removeWord(_ word: String) {
        vocabulary.removeAll { $0 == word }
        save()
    }

    func addRule(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return }
        replacements.removeAll { $0.from.caseInsensitiveCompare(f) == .orderedSame }
        replacements.append(Rule(from: f, to: t))
        save()
    }

    func removeRule(_ rule: Rule) {
        replacements.removeAll { $0.id == rule.id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Contents(vocabulary: vocabulary, replacements: replacements)) {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Application

    /// Case-insensitive, word-boundary replacement of every rule.
    func applyReplacements(to text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var result = text
        for rule in replacements {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: rule.from) + "\\b"
            let template = NSRegularExpression.escapedTemplate(for: rule.to)
            result = result.replacingOccurrences(of: pattern,
                                                 with: template,
                                                 options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}
