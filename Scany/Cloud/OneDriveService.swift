import Foundation
import UIKit

#if canImport(MSAL)
import MSAL
#endif

/// OneDrive uploads via Microsoft Graph.
/// Auth prefers MSAL (SPM) and falls back to PKCE + Keychain tokens.
final class OneDriveService: CloudFileStore {
    let provider: CloudProvider = .oneDrive
    var usesSimulation: Bool { !CloudConfig.OneDrive.isConfigured }

    private let tokenAccount = "onedrive.oauth"
    private let oauth = OAuthSession()

    #if canImport(MSAL)
    private var application: MSALPublicClientApplication?
    private var cachedAccount: MSALAccount?
    #endif

    func connect(from presenter: UIViewController) async throws -> CloudAccount {
        if usesSimulation {
            throw CloudError.notConfigured
        }
        #if canImport(MSAL)
        return try await signInWithMSAL(presenter: presenter)
        #else
        return try await signInWithPKCE()
        #endif
    }

    func restoreSession() async -> CloudAccount? {
        guard !usesSimulation else { return nil }
        #if canImport(MSAL)
        do {
            let app = try msalApp()
            guard let account = try app.allAccounts().first else { return nil }
            cachedAccount = account
            let token = try await silentToken(app: app, account: account)
            return try await fetchProfile(accessToken: token)
        } catch {
            return nil
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
        #if canImport(MSAL)
        if let app = try? msalApp(), let account = try? app.allAccounts().first {
            try? app.remove(account)
        }
        cachedAccount = nil
        #endif
        KeychainStore.delete(account: tokenAccount)
    }

    func listFolders() async throws -> [CloudFolder] {
        let token = try await accessToken()
        var request = URLRequest(
            url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/children?$select=id,name,folder&$top=200")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        let json = CloudHTTP.jsonObject(from: data)
        let rows = json["value"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row["folder"] != nil,
                  let id = row["id"] as? String,
                  let name = row["name"] as? String
            else { return nil }
            return CloudFolder(id: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createFolder(named name: String) async throws -> CloudFolder {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/children")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "rename"
        ])
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        let json = CloudHTTP.jsonObject(from: data)
        guard let id = json["id"] as? String else {
            throw CloudError.message("OneDrive did not return a folder id.")
        }
        return CloudFolder(id: id, name: json["name"] as? String ?? name)
    }

    func uploadPDF(data: Data, filename: String, folder: CloudFolder) async throws -> CloudUploadResult {
        let token = try await accessToken()
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(folder.id):/\(encodedName):/content")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(responseData, response)
        let json = CloudHTTP.jsonObject(from: responseData)
        return CloudUploadResult(
            provider: .oneDrive,
            folderName: folder.name,
            fileName: filename,
            remoteID: json["id"] as? String,
            isSimulated: false
        )
    }

    // MARK: - Auth

    private func accessToken() async throws -> String {
        #if canImport(MSAL)
        let app = try msalApp()
        if let account = cachedAccount ?? (try? app.allAccounts().first) {
            return try await silentToken(app: app, account: account)
        }
        #endif
        guard let tokens = KeychainStore.json(OAuthTokens.self, account: tokenAccount) else {
            throw CloudError.notSignedIn
        }
        return try await refreshed(tokens).accessToken
    }

    #if canImport(MSAL)
    private func msalApp() throws -> MSALPublicClientApplication {
        if let application { return application }
        let authorityURL = URL(string: "https://login.microsoftonline.com/\(CloudConfig.OneDrive.tenantID)")!
        let authority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: CloudConfig.OneDrive.clientID,
            redirectUri: CloudConfig.OneDrive.redirectURI,
            authority: authority
        )
        let app = try MSALPublicClientApplication(configuration: config)
        application = app
        return app
    }

    @MainActor
    private func signInWithMSAL(presenter: UIViewController) async throws -> CloudAccount {
        let app = try msalApp()
        let web = MSALWebviewParameters(authPresentationViewController: presenter)
        let params = MSALInteractiveTokenParameters(scopes: CloudConfig.OneDrive.scopes, webviewParameters: web)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: CloudError.cancelled)
                }
            }
        }
        cachedAccount = result.account
        return CloudAccount(
            email: result.account.username ?? "OneDrive account",
            displayName: result.account.username ?? "OneDrive account"
        )
    }

    private func silentToken(app: MSALPublicClientApplication, account: MSALAccount) async throws -> String {
        let params = MSALSilentTokenParameters(scopes: CloudConfig.OneDrive.scopes, account: account)
        return try await withCheckedThrowingContinuation { continuation in
            app.acquireTokenSilent(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = result?.accessToken {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: CloudError.notSignedIn)
                }
            }
        }
    }
    #endif

    @MainActor
    private func signInWithPKCE() async throws -> CloudAccount {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let items: [String: String] = [
            "client_id": CloudConfig.OneDrive.clientID,
            "response_type": "code",
            "redirect_uri": CloudConfig.OneDrive.redirectURI,
            "response_mode": "query",
            "scope": CloudConfig.OneDrive.scopes.joined(separator: " "),
            "code_challenge": challenge,
            "code_challenge_method": "S256"
        ]
        let url = URL(
            string: "https://login.microsoftonline.com/\(CloudConfig.OneDrive.tenantID)/oauth2/v2.0/authorize?\(CloudHTTP.queryItems(items))"
        )!
        let callback = try await oauth.signIn(authURL: url, callbackScheme: CloudConfig.OneDrive.urlScheme)
        let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        guard let code else { throw CloudError.message("Microsoft did not return an auth code.") }
        let tokens = try await exchangeMicrosoftCode(code, verifier: verifier)
        try KeychainStore.setJSON(tokens, account: tokenAccount)
        return try await fetchProfile(accessToken: tokens.accessToken)
    }

    private func exchangeMicrosoftCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        var request = URLRequest(
            url: URL(string: "https://login.microsoftonline.com/\(CloudConfig.OneDrive.tenantID)/oauth2/v2.0/token")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudHTTP.formEncode([
            "client_id": CloudConfig.OneDrive.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": CloudConfig.OneDrive.redirectURI
        ])
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        return try tokens(from: data)
    }

    private func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if !tokens.isExpired { return tokens }
        guard let refresh = tokens.refreshToken else { throw CloudError.notSignedIn }
        var request = URLRequest(
            url: URL(string: "https://login.microsoftonline.com/\(CloudConfig.OneDrive.tenantID)/oauth2/v2.0/token")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudHTTP.formEncode([
            "client_id": CloudConfig.OneDrive.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
            "scope": CloudConfig.OneDrive.scopes.joined(separator: " ")
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
            throw CloudError.message("Microsoft token response was missing access_token.")
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
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.send(request)
        try CloudHTTP.requireOK(data, response)
        let json = CloudHTTP.jsonObject(from: data)
        let email = (json["userPrincipalName"] as? String) ?? (json["mail"] as? String) ?? "OneDrive account"
        return CloudAccount(email: email, displayName: json["displayName"] as? String ?? email)
    }
}
