import Foundation

/// In-memory document assembled during a scan session.
struct ScanDocument: Identifiable {
    let id: UUID
    var title: String
    var pages: [ScannedPage]
    /// When true, every page is enhanced and the PDF uses the enhanced images.
    var autoEnhanceAllPages: Bool
    let createdAt: Date
    let storageDirectory: URL

    init(
        id: UUID = UUID(),
        title: String = ScanDocument.makeDefaultTitle(),
        pages: [ScannedPage] = [],
        autoEnhanceAllPages: Bool = false,
        createdAt: Date = Date(),
        storageDirectory: URL
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.autoEnhanceAllPages = autoEnhanceAllPages
        self.createdAt = createdAt
        self.storageDirectory = storageDirectory
    }

    static func makeDefaultTitle(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scan \(formatter.string(from: now))"
    }

    static func makeSessionDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanySessions", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func removeFromDisk() {
        try? FileManager.default.removeItem(at: storageDirectory)
    }
}
