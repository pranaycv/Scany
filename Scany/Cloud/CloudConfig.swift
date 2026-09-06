import Foundation

/// OAuth client IDs and redirect URLs.
///
/// Replace the `YOUR_…` placeholders before shipping live Drive / OneDrive
/// uploads. Until they are replaced, Scany uses a sandbox “cloud upload
/// simulation” so Settings and export can be exercised in Simulator.
enum CloudConfig {
    enum Google {
        /// iOS OAuth client ID from Google Cloud Console (application type: iOS).
        /// Example: `1234567890-abcdef.apps.googleusercontent.com`
        static let clientID = "YOUR_GOOGLE_IOS_CLIENT_ID.apps.googleusercontent.com"

        /// Optional server/web client ID if you later add backend token exchange.
        static let serverClientID = ""

        /// Scope limited to files this app creates or opens.
        static let scopes = [
            "https://www.googleapis.com/auth/drive.file",
            "https://www.googleapis.com/auth/userinfo.email"
        ]

        /// Reversed client ID — must also be listed as a CFBundleURL scheme.
        static var reversedClientID: String {
            let trimmed = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(trimmed)"
        }

        static var urlScheme: String { reversedClientID }

        static var redirectURI: String { "\(urlScheme):/oauth2redirect/google" }

        static var isConfigured: Bool {
            !clientID.hasPrefix("YOUR_") && clientID.contains(".apps.googleusercontent.com")
        }
    }

    enum OneDrive {
        /// Application (client) ID from an Azure AD app registration.
        static let clientID = "YOUR_AZURE_AD_CLIENT_ID"

        /// `common` for multi-tenant personal + work; or a specific tenant GUID.
        static let tenantID = "common"

        /// Must match Azure Authentication → Redirect URI exactly
        /// (`msauth.<bundle-id>://auth`).
        static let redirectURI = "msauth.com.pranaycv.Scany://auth"

        static let scopes = [
            "Files.ReadWrite",
            "User.Read",
            "offline_access"
        ]

        static var urlScheme: String { "msauth.com.pranaycv.Scany" }

        static var isConfigured: Bool {
            !clientID.hasPrefix("YOUR_") && clientID.count >= 20
        }
    }

    static var googleUsesLiveAPI: Bool { Google.isConfigured }
    static var oneDriveUsesLiveAPI: Bool { OneDrive.isConfigured }
}
