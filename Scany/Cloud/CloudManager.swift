import Foundation
import SwiftUI
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if canImport(MSAL)
import MSAL
#endif

@MainActor
final class CloudManager: ObservableObject {
    @Published private(set) var google: CloudConnection?
    @Published private(set) var oneDrive: CloudConnection?
    @Published var lastUsedProvider: CloudProvider?
    @Published var statusMessage: String?

    private let googleLive = GoogleDriveService()
    private let oneDriveLive = OneDriveService()
    private let googleSim = SimulatedCloudStore(provider: .googleDrive)
    private let oneDriveSim = SimulatedCloudStore(provider: .oneDrive)

    init() {
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
        if let entry = saved.oneDrive {
            oneDrive = CloudConnection(
                provider: .oneDrive,
                account: entry.account,
                folder: entry.folder,
                isSimulated: entry.isSimulated
            )
        }
        configureSDKs()
        Task { await restoreLiveSessions() }
    }

    private func configureSDKs() {
        #if canImport(GoogleSignIn)
        if CloudConfig.Google.isConfigured {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: CloudConfig.Google.clientID)
        }
        #endif
    }

    var connectedProviders: [CloudProvider] {
        [google, oneDrive].compactMap { $0?.provider }
    }

    var readyProviders: [CloudProvider] {
        [google, oneDrive].compactMap { connection in
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
        case .oneDrive: return oneDrive
        }
    }

    func isSimulated(_ provider: CloudProvider) -> Bool {
        store(for: provider).usesSimulation
    }

    func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        if GIDSignIn.sharedInstance.handle(url) { return true }
        #endif
        #if canImport(MSAL)
        if MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil) {
            return true
        }
        #endif
        return url.scheme?.hasPrefix("scany") == true
            || url.scheme?.hasPrefix("msauth.") == true
            || url.scheme?.hasPrefix("com.googleusercontent.apps.") == true
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
        case .oneDrive: oneDrive = nil
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
        let data = try Data(contentsOf: pdfURL)
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
        if google == nil, let account = await googleLive.restoreSession() {
            google = CloudConnection(
                provider: .googleDrive,
                account: account,
                folder: CloudDestinationStore.load().google?.folder,
                isSimulated: false
            )
        }
        if oneDrive == nil, let account = await oneDriveLive.restoreSession() {
            oneDrive = CloudConnection(
                provider: .oneDrive,
                account: account,
                folder: CloudDestinationStore.load().oneDrive?.folder,
                isSimulated: false
            )
        }
        persist()
    }

    private func ensureDefaultFolder(_ provider: CloudProvider) async throws -> CloudFolder {
        let existing = try await activeStore(provider).listFolders()
        if let scany = existing.first(where: { $0.name.compare("Scany", options: .caseInsensitive) == .orderedSame }) {
            return scany
        }
        return try await activeStore(provider).createFolder(named: "Scany")
    }

    private func store(for provider: CloudProvider) -> CloudFileStore {
        switch provider {
        case .googleDrive: return googleLive
        case .oneDrive: return oneDriveLive
        }
    }

    private func simulated(_ provider: CloudProvider) -> SimulatedCloudStore {
        switch provider {
        case .googleDrive: return googleSim
        case .oneDrive: return oneDriveSim
        }
    }

    private func activeStore(_ provider: CloudProvider) -> CloudFileStore {
        store(for: provider).usesSimulation ? simulated(provider) : store(for: provider)
    }

    private func setConnection(_ connection: CloudConnection) {
        switch connection.provider {
        case .googleDrive: google = connection
        case .oneDrive: oneDrive = connection
        }
    }

    private func persist() {
        var record = CloudDestinationStore.Record()
        if let google {
            record.google = .init(account: google.account, folder: google.folder, isSimulated: google.isSimulated)
        }
        if let oneDrive {
            record.oneDrive = .init(account: oneDrive.account, folder: oneDrive.folder, isSimulated: oneDrive.isSimulated)
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
