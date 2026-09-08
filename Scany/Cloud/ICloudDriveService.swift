import Foundation
import UIKit
import UniformTypeIdentifiers

/// Saves PDFs into a folder the user picks in Files (iCloud Drive, On My iPhone, etc.).
/// Uses a security-scoped bookmark — no iCloud entitlement, so a personal Apple team can still build.
final class ICloudDriveService: CloudFileStore {
    let provider: CloudProvider = .iCloud
    let usesSimulation = false

    static let rootFolderID = "."

    private let bookmarkAccount = "icloud.bookmark"
    private let nameAccount = "icloud.folderName"
    private let fileManager = FileManager.default
    private var pickerSession: FolderPickSession?

    func connect(toPickedFolder url: URL) throws -> CloudAccount {
        try persistBookmark(url)
        return account(for: url)
    }

    func connect(from presenter: UIViewController) async throws -> CloudAccount {
        defer { pickerSession = nil }
        let url = try await pickFolder(from: presenter)
        try persistBookmark(url)
        return account(for: url)
    }

    func restoreSession() async -> CloudAccount? {
        guard let url = try? resolvedBookmarkURL() else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return account(for: url)
    }

    func disconnect() async {
        KeychainStore.delete(account: bookmarkAccount)
        KeychainStore.delete(account: nameAccount)
    }

    func listFolders() async throws -> [CloudFolder] {
        try withBookmarkedURL { root in
            var folders = [CloudFolder(id: Self.rootFolderID, name: root.lastPathComponent)]
            let urls = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            folders.append(contentsOf: urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return nil }
                return CloudFolder(id: url.lastPathComponent, name: url.lastPathComponent)
            })
            return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func createFolder(named name: String) async throws -> CloudFolder {
        let trimmed = try Self.validatedFolderName(name)
        return try withBookmarkedURL { root in
            let url = root.appendingPathComponent(trimmed, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return CloudFolder(id: trimmed, name: trimmed)
        }
    }

    func uploadPDF(data: Data, filename: String, folder: CloudFolder) async throws -> CloudUploadResult {
        let destName = try withBookmarkedURL { root -> String in
            let directory: URL
            if folder.id == Self.rootFolderID {
                directory = root
            } else {
                let trimmed = try Self.validatedFolderName(folder.id)
                directory = root.appendingPathComponent(trimmed, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let dest = directory.appendingPathComponent(filename)
            try writeCoordinated(data, to: dest)
            return dest.lastPathComponent
        }
        return CloudUploadResult(
            provider: .iCloud,
            folderName: folder.name,
            fileName: destName,
            remoteID: destName,
            isSimulated: false
        )
    }

    // MARK: - Private

    static func validatedFolderName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudError.message("Enter a folder name.") }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw CloudError.message("Enter a valid folder name.")
        }
        return trimmed
    }

    private func account(for url: URL) -> CloudAccount {
        CloudAccount(email: url.lastPathComponent, displayName: "iCloud")
    }

    private func pickFolder(from presenter: UIViewController) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = FolderPickSession(continuation: continuation)
                self.pickerSession = session
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                picker.delegate = session
                picker.allowsMultipleSelection = false
                picker.modalPresentationStyle = .formSheet
                var host = presenter
                while let nested = host.presentedViewController {
                    host = nested
                }
                guard host.viewIfLoaded?.window != nil else {
                    session.finish(.failure(CloudError.message("Could not open the folder picker.")))
                    return
                }
                host.present(picker, animated: true)
            }
        }
    }

    private func persistBookmark(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try KeychainStore.set(data, account: bookmarkAccount)
            try KeychainStore.setJSON(["name": url.lastPathComponent], account: nameAccount)
        } catch {
            throw CloudError.message("Scany could not keep access to that folder. In Files, open iCloud Drive, select a folder, then tap Open.")
        }
    }

    private func resolvedBookmarkURL() throws -> URL {
        guard let data = KeychainStore.data(account: bookmarkAccount) else {
            throw CloudError.notSignedIn
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try KeychainStore.set(refreshed, account: bookmarkAccount)
        }
        return url
    }

    private func withBookmarkedURL<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolvedBookmarkURL()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private func writeCoordinated(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { dest in
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError {
            throw CloudError.message(coordinatorError.localizedDescription)
        }
        if let writeError {
            throw writeError
        }
    }
}

private final class FolderPickSession: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL, Error>?

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            finish(.failure(CloudError.cancelled))
            return
        }
        finish(.success(url))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(CloudError.cancelled))
    }

    func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
