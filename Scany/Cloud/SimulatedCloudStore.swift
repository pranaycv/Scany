import Foundation
import UIKit

/// Writes PDFs into the app sandbox so Settings / export work in Simulator
/// (or on device before OAuth client IDs are filled in).
final class SimulatedCloudStore: CloudFileStore {
    let provider: CloudProvider
    let usesSimulation = true

    private let fileManager = FileManager.default

    init(provider: CloudProvider) {
        self.provider = provider
    }

    private var root: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("CloudUploadSimulation", isDirectory: true)
            .appendingPathComponent(provider.displayName, isDirectory: true)
    }

    func connect(from presenter: UIViewController) async throws -> CloudAccount {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return CloudAccount(
            email: "simulator@scany.local",
            displayName: "\(provider.displayName) simulation"
        )
    }

    func restoreSession() async -> CloudAccount? {
        nil
    }

    func disconnect() async {}

    func listFolders() async throws -> [CloudFolder] {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return CloudFolder(id: url.lastPathComponent, name: url.lastPathComponent)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createFolder(named name: String) async throws -> CloudFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudError.message("Enter a folder name.") }
        let url = root.appendingPathComponent(trimmed, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return CloudFolder(id: trimmed, name: trimmed)
    }

    func uploadPDF(data: Data, filename: String, folder: CloudFolder) async throws -> CloudUploadResult {
        try await uploadFiles(
            [CloudBinaryUpload(data: data, filename: filename, mimeType: "application/pdf")],
            folder: folder,
            subfolder: nil
        )
    }

    func uploadFiles(_ files: [CloudBinaryUpload], folder: CloudFolder, subfolder: String?) async throws -> CloudUploadResult {
        var directory = root.appendingPathComponent(folder.id, isDirectory: true)
        if let subfolder {
            directory = directory.appendingPathComponent(subfolder, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var lastName = ""
        var lastPath = directory.path
        for file in files {
            let fileURL = directory.appendingPathComponent(file.filename)
            try file.data.write(to: fileURL, options: .atomic)
            lastName = file.filename
            lastPath = fileURL.path
        }
        return CloudUploadResult(
            provider: provider,
            folderName: subfolder ?? folder.name,
            fileName: lastName,
            remoteID: lastPath,
            isSimulated: true
        )
    }
}
