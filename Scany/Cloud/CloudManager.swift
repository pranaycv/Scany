import Foundation
import SwiftUI
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
final class CloudManager: ObservableObject {
    @Published private(set) var google: CloudConnection?
    @Published private(set) var iCloud: CloudConnection?
    @Published var lastUsedProvider: CloudProvider?
    @Published var statusMessage: String?

    private let googleLive: GoogleDriveService
    private let iCloudLive: ICloudDriveService
    private let googleSim: SimulatedCloudStore
    private let iCloudSim: SimulatedCloudStore
    private var didRestoreSessions = false

    init() {
        googleLive = GoogleDriveService()
        iCloudLive = ICloudDriveService()
        googleSim = SimulatedCloudStore(provider: .googleDrive)
        iCloudSim = SimulatedCloudStore(provider: .iCloud)

        let saved = CloudDestinationStore.load()
        lastUsedProvider = saved.lastProvider
        if let entry = saved.google {
            google = CloudConnection(
                provider: .googleDrive,
                account: entry.account,
                folder: entry.folder,
                isSimulated: entry.isSimulated
            )
        }
        if let entry = saved.iCloud {
            iCloud = CloudConnection(
                provider: .iCloud,
                account: entry.account,
                folder: entry.folder,
                isSimulated: entry.isSimulated
            )
        }
        configureSDKs()
    }

    /// Google restore talks to the network. Run after the first frame so Home can paint.
    func restoreLiveSessionsIfNeeded() async {
        guard !didRestoreSessions else { return }
        didRestoreSessions = true
        await restoreLiveSessions()
    }

    private func configureSDKs() {
        #if canImport(GoogleSignIn)
        if CloudConfig.Google.isConfigured {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: CloudConfig.Google.clientID)
        }
        #endif
    }

    var connectedProviders: [CloudProvider] {
        [google, iCloud].compactMap { $0?.provider }
    }

    var readyProviders: [CloudProvider] {
        [google, iCloud].compactMap { connection in
            guard let connection, connection.isReadyToUpload else { return nil }
            return connection.provider
        }
    }

    var preferredUploadProvider: CloudProvider? {
        if let lastUsedProvider, readyProviders.contains(lastUsedProvider) {
            return lastUsedProvider
        }
        if readyProviders.count == 1 {
            return readyProviders[0]
        }
        return nil
    }

    func connection(for provider: CloudProvider) -> CloudConnection? {
        switch provider {
        case .googleDrive: return google
        case .iCloud: return iCloud
        }
    }

    func isSimulated(_ provider: CloudProvider) -> Bool {
        store(for: provider).usesSimulation
    }

    func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        if GIDSignIn.sharedInstance.handle(url) { return true }
        #endif
        return url.scheme?.hasPrefix("scany") == true
            || url.scheme?.hasPrefix("com.googleusercontent.apps.") == true
    }

    func connectICloud(folderURL: URL) async {
        statusMessage = nil
        do {
            let account = try iCloudLive.connect(toPickedFolder: folderURL)
            let folder = CloudFolder(id: ICloudDriveService.rootFolderID, name: folderURL.lastPathComponent)
            setConnection(
                CloudConnection(
                    provider: .iCloud,
                    account: account,
                    folder: folder,
                    isSimulated: false
                )
            )
            lastUsedProvider = .iCloud
            persist()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connect(_ provider: CloudProvider) async {
        statusMessage = nil
        do {
            let presenter = PresentingViewController.top()
            guard let presenter else {
                throw CloudError.message("Could not present sign-in.")
            }
            let account: CloudAccount
            if store(for: provider).usesSimulation {
                account = try await simulated(provider).connect(from: presenter)
            } else {
                account = try await store(for: provider).connect(from: presenter)
            }
            var connection = CloudConnection(
                provider: provider,
                account: account,
                folder: connection(for: provider)?.folder,
                isSimulated: store(for: provider).usesSimulation
            )
            if connection.folder == nil {
                connection.folder = try? await ensureDefaultFolder(provider)
            }
            setConnection(connection)
            persist()
        } catch is CancellationError {
            statusMessage = nil
        } catch let error as CloudError where error.isCancelled {
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func disconnect(_ provider: CloudProvider) async {
        await store(for: provider).disconnect()
        await simulated(provider).disconnect()
        switch provider {
        case .googleDrive: google = nil
        case .iCloud: iCloud = nil
        }
        if lastUsedProvider == provider {
            lastUsedProvider = readyProviders.first
        }
        persist()
    }

    func setFolder(_ folder: CloudFolder, for provider: CloudProvider) {
        guard var connection = connection(for: provider) else { return }
        connection.folder = folder
        setConnection(connection)
        lastUsedProvider = provider
        persist()
    }

    func listFolders(_ provider: CloudProvider) async throws -> [CloudFolder] {
        try await activeStore(provider).listFolders()
    }

    func createFolder(named name: String, provider: CloudProvider) async throws -> CloudFolder {
        let folder = try await activeStore(provider).createFolder(named: name)
        setFolder(folder, for: provider)
        return folder
    }

    func upload(pdfURL: URL, filename: String, provider: CloudProvider) async throws -> CloudUploadResult {
        guard let connection = connection(for: provider), let folder = connection.folder else {
            throw CloudError.noFolder
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: pdfURL)
        }.value
        let result = try await activeStore(provider).uploadPDF(
            data: data,
            filename: filename,
            folder: folder
        )
        lastUsedProvider = provider
        persist()
        return result
    }

    // MARK: - Private

    private func restoreLiveSessions() async {
        if let account = await googleLive.restoreSession() {
            google = CloudConnection(
                provider: .googleDrive,
                account: account,
                folder: google?.folder ?? CloudDestinationStore.load().google?.folder,
                isSimulated: false
            )
        }
        if iCloud == nil, let account = await iCloudLive.restoreSession() {
            iCloud = CloudConnection(
                provider: .iCloud,
                account: account,
                folder: CloudDestinationStore.load().iCloud?.folder,
                isSimulated: false
            )
        }
        persist()
    }

    private func ensureDefaultFolder(_ provider: CloudProvider) async throws -> CloudFolder {
        let existing = try await activeStore(provider).listFolders()
        if provider == .iCloud {
            if let root = existing.first(where: { $0.id == ICloudDriveService.rootFolderID }) {
                return root
            }
            if let first = existing.first {
                return first
            }
        }
        if let scany = existing.first(where: { $0.name.compare("Scany", options: .caseInsensitive) == .orderedSame }) {
            return scany
        }
        return try await activeStore(provider).createFolder(named: "Scany")
    }

    private func store(for provider: CloudProvider) -> CloudFileStore {
        switch provider {
        case .googleDrive: return googleLive
        case .iCloud: return iCloudLive
        }
    }

    private func simulated(_ provider: CloudProvider) -> SimulatedCloudStore {
        switch provider {
        case .googleDrive: return googleSim
        case .iCloud: return iCloudSim
        }
    }

    private func activeStore(_ provider: CloudProvider) -> CloudFileStore {
        store(for: provider).usesSimulation ? simulated(provider) : store(for: provider)
    }

    private func setConnection(_ connection: CloudConnection) {
        switch connection.provider {
        case .googleDrive: google = connection
        case .iCloud: iCloud = connection
        }
    }

    private func persist() {
        var record = CloudDestinationStore.Record()
        if let google {
            record.google = .init(account: google.account, folder: google.folder, isSimulated: google.isSimulated)
        }
        if let iCloud {
            record.iCloud = .init(account: iCloud.account, folder: iCloud.folder, isSimulated: iCloud.isSimulated)
        }
        record.lastProvider = lastUsedProvider
        CloudDestinationStore.save(record)
    }
}

private extension CloudError {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
