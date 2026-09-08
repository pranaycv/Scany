import Foundation

/// In-memory document assembled during a scan session.
struct ScanDocument: Identifiable {
    let id: UUID
    var title: String
    var pages: [ScannedPage]
    /// When true, every page is enhanced and the PDF uses the enhanced images.
    var autoEnhanceAllPages: Bool
    /// When true, pages are deskewed to line up text/rules unless the user rotated them.
    var autoRotateAllPages: Bool
    let createdAt: Date
    let storageDirectory: URL

    init(
        id: UUID = UUID(),
        title: String = "",
        pages: [ScannedPage] = [],
        autoEnhanceAllPages: Bool = false,
        autoRotateAllPages: Bool = false,
        createdAt: Date = Date(),
        storageDirectory: URL
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.autoEnhanceAllPages = autoEnhanceAllPages
        self.autoRotateAllPages = autoRotateAllPages
        self.createdAt = createdAt
        self.storageDirectory = storageDirectory
    }

    static func makeDefaultTitle(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: now)
    }

    static func sanitizedFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "\\", with: "-")
    }

    /// Combines the typed name with an optional timestamp. Empty if both are off/blank.
    static func makeExportFileName(
        title: String,
        appendDateTime: Bool,
        now: Date = Date()
    ) -> String {
        let base = sanitizedFileName(title)
        if appendDateTime {
            let stamp = makeDefaultTitle(now: now)
            return base.isEmpty ? stamp : "\(base) \(stamp)"
        }
        return base
    }

    static func makeSessionDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanySessions", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func removeFromDisk() {
        let sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanySessions", isDirectory: true)
        guard storageDirectory.path.hasPrefix(sessionsRoot.path) else { return }
        try? FileManager.default.removeItem(at: storageDirectory)
    }
}

enum ScanPreferences {
    private static let autoEnhanceKey = "scany.autoEnhanceEnabled"
    private static let autoRotateKey = "scany.autoRotateEnabled"
    private static let appendDateTimeKey = "scany.appendDateTimeToFileName"

    /// Last Enhance choice in page preview. New captures start with this value.
    static var autoEnhanceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoEnhanceKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoEnhanceKey) }
    }

    /// Last Auto-rotate choice. New captures keep using this after the review toggle was removed.
    static var autoRotateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoRotateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoRotateKey) }
    }

    /// Last “Add date and time” choice on the review screen.
    static var appendDateTimeToFileName: Bool {
        get { UserDefaults.standard.bool(forKey: appendDateTimeKey) }
        set { UserDefaults.standard.set(newValue, forKey: appendDateTimeKey) }
    }
}
