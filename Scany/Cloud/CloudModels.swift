import Foundation
import UIKit

enum CloudProvider: String, Codable, CaseIterable, Identifiable {
    case googleDrive
    case iCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .iCloud: return "iCloud"
        }
    }

    var saveActionTitle: String {
        switch self {
        case .googleDrive: return "Save to Drive"
        case .iCloud: return "Save to iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .googleDrive: return "externaldrive.badge.icloud"
        case .iCloud: return "icloud"
        }
    }
}

struct CloudAccount: Equatable, Codable {
    var email: String
    var displayName: String
}

struct CloudFolder: Equatable, Identifiable, Codable {
    var id: String
    var name: String
}

struct CloudConnection: Equatable {
    var provider: CloudProvider
    var account: CloudAccount
    var folder: CloudFolder?
    var isSimulated: Bool

    var isReadyToUpload: Bool { folder != nil }
}

struct CloudUploadResult: Equatable {
    var provider: CloudProvider
    var folderName: String
    var fileName: String
    var remoteID: String?
    var isSimulated: Bool
}

enum CloudError: LocalizedError, Sendable {
    case notConfigured
    case notSignedIn
    case noFolder
    case cancelled
    case http(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your OAuth client ID in CloudConfig.swift to use live cloud upload."
        case .notSignedIn:
            return "Connect an account in Settings first."
        case .noFolder:
            return "Choose a destination folder before saving."
        case .cancelled:
            return "Sign-in was cancelled."
        case .http(let code, let body):
            return "Cloud request failed (\(code)): \(body)"
        case .message(let text):
            return text
        }
    }
}

protocol CloudFileStore: AnyObject {
    var provider: CloudProvider { get }
    var usesSimulation: Bool { get }

    func connect(from presenter: UIViewController) async throws -> CloudAccount
    func restoreSession() async -> CloudAccount?
    func disconnect() async
    func listFolders() async throws -> [CloudFolder]
    func createFolder(named name: String) async throws -> CloudFolder
    func uploadPDF(data: Data, filename: String, folder: CloudFolder) async throws -> CloudUploadResult
}
