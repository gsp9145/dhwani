import AppKit

/// On-demand transforms: select text anywhere, hit ⌥⌘1–4 (or use the menu),
/// and the selection is rewritten in place — copy → on-device model → paste
/// over the selection. Deliberately user-invoked and visible (⌘Z undoes it):
/// this is the safe home for actual rewriting, unlike inline polish.
@available(macOS 26.0, *)
enum TransformService {
    struct Kind {
        let title: String
        let doneLabel: String
        let instructions: String
    }

    static let kinds: [Kind] = [
        Kind(title: "Make Formal",
             doneLabel: "✦ Made formal",
             instructions: "Rewrite the text between <text> tags in a formal, professional tone. Same language, same meaning, keep every fact and name. Output only the rewritten text — no quotes, no commentary."),
        Kind(title: "Make Casual",
             doneLabel: "✦ Made casual",
             instructions: "Rewrite the text between <text> tags in a relaxed, casual tone. Same language, same meaning, keep every fact and name. Output only the rewritten text — no quotes, no commentary."),
        Kind(title: "Bullet List",
             doneLabel: "✦ Bulleted",
             instructions: "Reformat the text between <text> tags as a concise dash bullet list. Keep the author's wording and every piece of information; do not add anything. Output only the list."),
        Kind(title: "Tighten",
             doneLabel: "✦ Tightened",
             instructions: "Rewrite the text between <text> tags more concisely. Do not lose any information, change the meaning, or shift the tone. Same language. Output only the rewritten text."),
    ]

    private static var running = false

    static func run(_ index: Int) {
        guard kinds.indices.contains(index), !running else { return }
        guard AIFormatter.isAvailable else {
            HUD.shared.show(.error("Transforms need Apple Intelligence — enable it in System Settings"))
            HUD.shared.hide(after: 3)
            return
        }
        guard !SecureInput.isActive else {
            HUD.shared.show(.error("Secure input is on — transforms unavailable here"))
            HUD.shared.hide(after: 2.5)
            return
        }
        running = true
        let kind = kinds[index]
        let pb = NSPasteboard.general
        let originalItems = snapshot(pb)
        let beforeCopy = pb.changeCount
        DebugLog.log("transform: \(kind.title) requested")
        TextInserter.postEditShortcut("c", ansiFallback: 8) // kVK_ANSI_C

        Task { @MainActor in
            defer { running = false }
            // Wait for the copy to land.
            var waited = 0.0
            while pb.changeCount == beforeCopy, waited < 0.6 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 0.05
            }
            guard pb.changeCount != beforeCopy,
                  let selection = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selection.isEmpty else {
                restore(pb, items: originalItems)
                HUD.shared.show(.error("Select some text first, then run the transform"))
                HUD.shared.hide(after: 2.5)
                return
            }

            HUD.shared.show(.processing)
            guard let result = await AIFormatter.transform(selection, instructions: kind.instructions) else {
                restore(pb, items: originalItems)
                HUD.shared.show(.error("Transform failed — your text is unchanged"))
                HUD.shared.hide(after: 2.5)
                return
            }
            DebugLog.log("transform: \(kind.title) '\(String(selection.prefix(40)))' → '\(String(result.prefix(40)))'")

            // Paste the result over the still-active selection.
            pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
            pb.setString(result, forType: .string)
            let ourChange = pb.changeCount
            try? await Task.sleep(nanoseconds: 80_000_000)
            TextInserter.postEditShortcut("v")

            HUD.shared.show(.info("\(kind.doneLabel) — ⌘Z undoes"))
            HUD.shared.hide(after: 1.6)

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if pb.changeCount == ourChange {
                restore(pb, items: originalItems)
            }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}
