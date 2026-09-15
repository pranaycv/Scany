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

struct CloudBinaryUpload {
    var data: Data
    var filename: String
    var mimeType: String
}

enum TrainingExport {
    static let folderName = "Train"
    static let missingDestination = "Connect iCloud and pick a folder in Settings first"

    static func successMessage(provider: CloudProvider) -> String {
        "Saved to Train in \(provider.displayName)"
    }

    static func fileStem(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "train_\(formatter.string(from: date))"
    }

    static func iso8601UTC(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func jsonData(
        filename: String,
        imageWidth: Int,
        imageHeight: Int,
        quad: DocumentQuad,
        createdAt: Date = Date()
    ) throws -> Data {
        let payload: [String: Any] = [
            "filename": filename,
            "image_width": imageWidth,
            "image_height": imageHeight,
            "quad_norm": quad.trainingQuadNorm(),
            "source": "manual",
            "created_at": iso8601UTC(createdAt),
            "presence": true
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func makeFiles(imageURL: URL, quad: DocumentQuad, createdAt: Date = Date()) throws -> [CloudBinaryUpload] {
        guard let photo = ScanImageFactory.ciImage(from: imageURL) else {
            throw CloudError.message("Could not load the page image.")
        }
        let width = Int(photo.extent.width.rounded())
        let height = Int(photo.extent.height.rounded())
        guard width > 0, height > 0 else {
            throw CloudError.message("Could not read the page image size.")
        }
        guard let imageData = ScanImageFactory.jpegData(from: photo, quality: 0.95) else {
            throw CloudError.message("Could not encode the page image.")
        }
        let stem = fileStem(at: createdAt)
        let imageName = "\(stem).jpg"
        let json = try jsonData(
            filename: imageName,
            imageWidth: width,
            imageHeight: height,
            quad: quad,
            createdAt: createdAt
        )
        return [
            CloudBinaryUpload(data: imageData, filename: imageName, mimeType: "image/jpeg"),
            CloudBinaryUpload(data: json, filename: "\(stem).json", mimeType: "application/json")
        ]
    }
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
    func uploadFiles(_ files: [CloudBinaryUpload], folder: CloudFolder, subfolder: String?) async throws -> CloudUploadResult
}
