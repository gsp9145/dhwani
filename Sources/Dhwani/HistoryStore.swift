import Foundation
import SQLite3

struct TranscriptEntry {
    let id: Int64
    let date: Date
    let text: String
    let appName: String
    let words: Int
    let durationMs: Int
}

/// Every dictation is stored twice: in SQLite (stats, recents) and appended to
/// a per-day markdown file in ~/Documents/Dhwani — the user's plain-text
/// transcript repository they can grep and copy from.
final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.gaurang.dhwani.history")
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let transcriptsFolder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Dhwani", isDirectory: true)
    }()

    private lazy var dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dhwani", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.transcriptsFolder, withIntermediateDirectories: true)

        let path = support.appendingPathComponent("dhwani.db").path
        if sqlite3_open(path, &db) == SQLITE_OK {
            exec("""
            CREATE TABLE IF NOT EXISTS transcripts(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                day TEXT NOT NULL,
                text TEXT NOT NULL,
                app_name TEXT,
                app_bundle_id TEXT,
                words INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL
            );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_transcripts_day ON transcripts(day);")
        } else {
            NSLog("Dhwani: failed to open history database at \(path)")
        }
    }

    private func exec(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK, let errorMessage {
            NSLog("Dhwani: sqlite error: \(String(cString: errorMessage))")
            sqlite3_free(errorMessage)
        }
    }

    func save(text: String, appName: String?, bundleID: String?, durationMs: Int) {
        let now = Date()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        queue.async {
            self.insertRow(date: now, text: text, appName: appName, bundleID: bundleID,
                           words: words, durationMs: durationMs)
            self.appendMarkdown(date: now, text: text, appName: appName)
        }
    }

    private func insertRow(date: Date, text: String, appName: String?, bundleID: String?,
                           words: Int, durationMs: Int) {
        let sql = "INSERT INTO transcripts (ts, day, text, app_name, app_bundle_id, words, duration_ms) VALUES (?,?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, dayFormatter.string(from: date), -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, text, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, appName ?? "Unknown", -1, sqliteTransient)
        sqlite3_bind_text(stmt, 5, bundleID ?? "", -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 6, Int64(words))
        sqlite3_bind_int64(stmt, 7, Int64(durationMs))
        sqlite3_step(stmt)
    }

    private func appendMarkdown(date: Date, text: String, appName: String?) {
        let day = dayFormatter.string(from: date)
        let file = Self.transcriptsFolder.appendingPathComponent("\(day).md")
        var chunk = ""
        if !FileManager.default.fileExists(atPath: file.path) {
            chunk += "# Dhwani transcripts — \(day)\n\n"
        }
        chunk += "### \(timeFormatter.string(from: date)) — \(appName ?? "Unknown")\n\n\(text)\n\n"
        guard let data = chunk.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: - Stats

    func todayStats() -> (notes: Int, words: Int) {
        stats(where: "day = '\(dayFormatter.string(from: Date()))'")
    }

    func totalStats() -> (notes: Int, words: Int) {
        stats(where: "1=1")
    }

    private func stats(where condition: String) -> (notes: Int, words: Int) {
        queue.sync {
            let sql = "SELECT COUNT(*), COALESCE(SUM(words), 0) FROM transcripts WHERE \(condition);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    /// Top destination apps by words dictated into them, optionally since a date.
    func appBreakdown(limit: Int, since: Date? = nil) -> [(app: String, notes: Int, words: Int)] {
        queue.sync {
            let filter = since != nil ? " WHERE ts >= ?" : ""
            let sql = "SELECT COALESCE(app_name,'Unknown'), COUNT(*), COALESCE(SUM(words),0) FROM transcripts\(filter) GROUP BY 1 ORDER BY 3 DESC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let since {
                sqlite3_bind_double(stmt, index, since.timeIntervalSince1970)
                index += 1
            }
            sqlite3_bind_int64(stmt, index, Int64(limit))
            var rows: [(String, Int, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let app = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "Unknown"
                rows.append((app, Int(sqlite3_column_int64(stmt, 1)), Int(sqlite3_column_int64(stmt, 2))))
            }
            return rows
        }
    }

    /// Total words dictated since a date (all apps, no limit).
    func wordsTotal(since: Date?) -> Int {
        queue.sync {
            let filter = since != nil ? " WHERE ts >= ?" : ""
            let sql = "SELECT COALESCE(SUM(words),0) FROM transcripts\(filter);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if let since {
                sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func recent(limit: Int) -> [TranscriptEntry] {
        queue.sync {
            let sql = "SELECT id, ts, text, app_name, words, duration_ms FROM transcripts ORDER BY ts DESC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var entries: [TranscriptEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let app = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                entries.append(TranscriptEntry(id: sqlite3_column_int64(stmt, 0),
                                               date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                               text: text,
                                               appName: app,
                                               words: Int(sqlite3_column_int64(stmt, 4)),
                                               durationMs: Int(sqlite3_column_int64(stmt, 5))))
            }
            return entries
        }
    }
}
