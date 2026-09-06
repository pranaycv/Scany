import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// Google Drive uploads via Drive API v3.
/// Auth prefers Google Sign-In (SPM) and falls back to PKCE + Keychain tokens.
final class GoogleDriveService: CloudFileStore {
    let provider: CloudProvider = .googleDrive
    var usesSimulation: Bool { !CloudConfig.Google.isConfigured }

    private let tokenAccount = "google.oauth"

    func connect(from presenter: UIViewController) async throws -> CloudAccount {
        if usesSimulation {
            throw CloudError.notConfigured
        }
        #if canImport(GoogleSignIn)
        return try await signInWithSDK(presenter: presenter)
        #else
        return try await signInWithPKCE()
        #endif
    }

    func restoreSession() async -> CloudAccount? {
        guard !usesSimulation else { return nil }
        #if canImport(GoogleSignIn)
        if let user = GIDSignIn.sharedInstance.currentUser {
            return account(from: user)
        }
        return await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, _ in
                continuation.resume(returning: user.map { self.account(from: $0) })
            }
        }
        #else
        guard let tokens = KeychainStore.json(OAuthTokens.self, account: tokenAccount) else { return nil }
        do {
            let valid = try await refreshed(tokens)
            return try await fetchProfile(accessToken: valid.accessToken)
        } catch {
            return nil
        }
        #endif
    }

    func disconnect() async {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        KeychainStore.delete(account: tokenAccount)
    }

    func listFolders() async throws -> [CloudFolder] {
        let token = try await accessToken()
        var collected: [CloudFolder] = []
        var pageToken: String?
        repeat {
            var items: [String: String] = [
                "q": "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
                "fields": "nextPageToken,files(id,name)",
                "pageSize": "100",
                "spaces": "drive"
            ]
            if let pageToken { items["pageToken"] = pageToken }
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?\(CloudHTTP.queryItems(items))")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await CloudHTTP.send(request)
            try CloudHTTP.requireOK(data, response)
            let json = CloudHTTP.jsonObject(from: data)
            let files = json["files"] as? [[String: Any]] ?? []
            collected.append(contentsOf: files.compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return CloudFolder(id: id, name: name)
            })
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createFolder(named name: String) async throws -> CloudFolder {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ])
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        let json = CloudHTTP.jsonObject(from: data)
        guard let id = json["id"] as? String else {
            throw CloudError.message("Drive did not return a folder id.")
        }
        return CloudFolder(id: id, name: json["name"] as? String ?? name)
    }

    func uploadPDF(data: Data, filename: String, folder: CloudFolder) async throws -> CloudUploadResult {
        let token = try await accessToken()
        let boundary = "scany-\(UUID().uuidString)"
        var metadata: [String: Any] = [
            "name": filename,
            "mimeType": "application/pdf"
        ]
        if folder.id != "root" {
            metadata["parents"] = [folder.id]
        }
        let metaData = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metaData)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(responseData, response)
        let json = CloudHTTP.jsonObject(from: responseData)
        return CloudUploadResult(
            provider: .googleDrive,
            folderName: folder.name,
            fileName: filename,
            remoteID: json["id"] as? String,
            isSimulated: false
        )
    }

    // MARK: - Auth

    private func accessToken() async throws -> String {
        #if canImport(GoogleSignIn)
        if let user = GIDSignIn.sharedInstance.currentUser {
            let refreshed = try await user.refreshTokensIfNeeded()
            return refreshed.accessToken.tokenString
        }
        #endif
        guard let tokens = KeychainStore.json(OAuthTokens.self, account: tokenAccount) else {
            throw CloudError.notSignedIn
        }
        return try await refreshed(tokens).accessToken
    }

    #if canImport(GoogleSignIn)
    @MainActor
    private func signInWithSDK(presenter: UIViewController) async throws -> CloudAccount {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: CloudConfig.Google.clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: CloudConfig.Google.scopes
        )
        return account(from: result.user)
    }

    private func account(from user: GIDGoogleUser) -> CloudAccount {
        CloudAccount(
            email: user.profile?.email ?? "Google account",
            displayName: user.profile?.name ?? user.profile?.email ?? "Google account"
        )
    }
    #endif

    @MainActor
    private func signInWithPKCE() async throws -> CloudAccount {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        var items: [String: String] = [
            "client_id": CloudConfig.Google.clientID,
            "redirect_uri": CloudConfig.Google.redirectURI,
            "response_type": "code",
            "scope": CloudConfig.Google.scopes.joined(separator: " "),
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent"
        ]
        let url = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?\(CloudHTTP.queryItems(items))")!
        let oauth = OAuthSession()
        let callback = try await oauth.signIn(authURL: url, callbackScheme: CloudConfig.Google.urlScheme)
        let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        guard let code else { throw CloudError.message("Google did not return an auth code.") }
        let tokens = try await exchangeGoogleCode(code, verifier: verifier)
        try KeychainStore.setJSON(tokens, account: tokenAccount)
        return try await fetchProfile(accessToken: tokens.accessToken)
    }

    private func exchangeGoogleCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudHTTP.formEncode([
            "client_id": CloudConfig.Google.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": CloudConfig.Google.redirectURI
        ])
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        return try tokens(from: data)
    }

    private func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if !tokens.isExpired { return tokens }
        guard let refresh = tokens.refreshToken else { throw CloudError.notSignedIn }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudHTTP.formEncode([
            "client_id": CloudConfig.Google.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ])
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        var next = try tokens(from: data)
        if next.refreshToken == nil { next.refreshToken = refresh }
        try KeychainStore.setJSON(next, account: tokenAccount)
        return next
    }

    private func tokens(from data: Data) throws -> OAuthTokens {
        let json = CloudHTTP.jsonObject(from: data)
        guard let access = json["access_token"] as? String else {
            throw CloudError.message("Google token response was missing access_token.")
        }
        let expires = json["expires_in"] as? Double ?? 3600
        return OAuthTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiry: Date().addingTimeInterval(expires),
            tokenType: json["token_type"] as? String ?? "Bearer"
        )
    }

    private func fetchProfile(accessToken: String) async throws -> CloudAccount {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        let json = CloudHTTP.jsonObject(from: data)
        let email = json["email"] as? String ?? "Google account"
        return CloudAccount(email: email, displayName: json["name"] as? String ?? email)
    }
}
