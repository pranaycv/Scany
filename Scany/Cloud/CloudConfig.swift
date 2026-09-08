import Foundation

/// OAuth client IDs for Google Drive. iCloud saves through the Files picker
/// (no iCloud container entitlement). Until Google.clientID is filled in, Drive
/// uses a sandbox simulation so Settings and export can be exercised in Simulator.
enum CloudConfig {
    enum Google {
        /// iOS OAuth client ID from Google Cloud Console (application type: iOS).
        /// Example: `1234567890-abcdef.apps.googleusercontent.com`
        static let clientID = "425117208853-qor7i4st2nd6kq29t51bkaktbnvgct7g.apps.googleusercontent.com"

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

    static var googleUsesLiveAPI: Bool { Google.isConfigured }
}
