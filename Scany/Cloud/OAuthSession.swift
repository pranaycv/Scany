import AuthenticationServices
import CommonCrypto
import Foundation
import UIKit

/// PKCE OAuth 2.0 via `ASWebAuthenticationSession`. Used when official SDKs
/// are not linked, or as a fallback if Sign-In / MSAL is unavailable.
///
/// The type is MainActor-isolated because `ASWebAuthenticationSession` must be
/// started from the main thread. Construction is MainActor-only (`make()` /
/// `signIn(authURL:callbackScheme:)`); do not allocate this from a service
/// stored-property default or a `nonisolated init`.
@MainActor
final class OAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    static func make() -> OAuthSession {
        OAuthSession()
    }

    static func signIn(authURL: URL, callbackScheme: String) async throws -> URL {
        try await make().signIn(authURL: authURL, callbackScheme: callbackScheme)
    }

    func signIn(
        authURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionErrorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: CloudError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: CloudError.cancelled)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            self.session = web
            if !web.start() {
                continuation.resume(throwing: CloudError.message("Could not start the sign-in session."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
            ?? UIWindow()
    }
}

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        let digest = Data(verifier.utf8).sha256()
        return digest.base64URLEncodedString()
    }
}

private extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
