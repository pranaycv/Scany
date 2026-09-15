# App Store 1.0 — paste-ready listing

Use this with App Store Connect. Version **1.0**, build **1**, bundle ID **`com.prnysoni.Scany`**, team **9M5QTLKHWQ**.

Legal URLs (must stay live). These are on the EyesRhythm domain so Google can verify Drive OAuth. They do not change `eyesrhythm.com`.

- Privacy: https://scany.eyesrhythm.com/privacy
- Support: https://scany.eyesrhythm.com/support
- Terms: https://scany.eyesrhythm.com/terms
- Marketing: https://scany.eyesrhythm.com
- Contact: prnysoni@gmail.com

## App information

| Field | Value |
| --- | --- |
| Name | Scany |
| Subtitle (30) | Scan to Drive or iCloud |
| Category | Productivity |
| Secondary | Business (optional) |
| Price | Free |
| Availability | All countries you serve |
| Age rating | 4+ (see questionnaire below) |

Promotional text (170):

```
100% free. No ads. Pages are processed on your iPhone — not on a Scany server. Save only to your Google Drive or iCloud when you choose.
```

Description:

```
Scany is a 100% free, ad-free document scanner for iPhone. Privacy first: every page is detected, cropped, and enhanced on your device. Scany has no cloud of its own. Your documents are never sent to a Scany server for processing or storage.

HOW IT WORKS
• Point the camera at a page — it does not have to be square to the frame
• A yellow box appears when the page is stable, then Scany captures on its own
• Scan as many pages as you need, then crop, rotate, or enhance
• Save a PDF to YOUR Google Drive or YOUR iCloud folder — only when you tap Save
• Clear the pages on the phone after upload. Scany does not keep a document library

PRIVACY FIRST — 100% FREE, NO ADS
• No Scany account and no Scany backend
• Scan processing stays on the iPhone
• We do not upload your pages to an open cloud or to our servers to process or store them
• The only copies that leave the phone are the PDF you choose to save into your own Drive or iCloud
• No ads, no trackers, no paywall

Requires iPhone with iOS 15 or later and a camera. Google Drive is optional. iCloud uses the Apple ID already on the phone.
```

Keywords (100, no app name):

```
document,pdf,scan,free,privacy,drive,icloud,camera,paper,receipt,adfree,office,pages
```

What’s New (1.0):

```
Welcome to Scany. Scan pages on your iPhone and save a PDF to Google Drive or iCloud.
```

## Screenshots

Required: one **6.9"** iPhone set (portrait). Accepted sizes: **1320×2868**, **1290×2796**, or **1260×2736**. iPhone 16 Pro Max / 15 Pro Max screenshots work. Apple scales the rest. iPad is not needed (iPhone only).

Take 5–6 real-device shots, in this order:

1. Home — logo, privacy line, Start scan
2. Camera — a real page with the **yellow** detection box
3. Camera — guidance such as Hold steady or Move closer
4. Review — stacked pages, Save to Drive / iCloud
5. Crop editor — corners on the page
6. Settings — Drive or iCloud connected with a folder name

No status-bar clutter, no unreleased UI, no “Add to train”. Use a readable printed page (not a confidential document).

## App Review notes

```
Scany is an iPhone document scanner. There is no Scany account.

Test without Google: Home → gear → Connect iCloud → pick any folder in Files → Start scan → point at a printed page → wait for the yellow box and auto-capture → Done → Save to iCloud.

Test Google Drive: use the demo account below. Google Sign-In authorizes Drive uploads only. It is not an app login, so Sign in with Apple is not offered.

Demo Google account:
Email: [FILL IN]
Password: [FILL IN]

Camera permission is required. A physical page in good light works best. iPhone 12 or newer recommended.
```

Create a dedicated Gmail for review, add it as an OAuth test user if the consent screen is still in Testing, and fill the two lines above before submit.

## Age rating

Answer **No** to violence, sexual content, profanity, alcohol/tobacco/drugs, gambling, horror, and unrestricted web access. The Google sign-in sheet is OAuth, not a browser.

User-generated content: **No** — scans are not posted for other people inside the app.

Result should be **4+**.

## App Privacy (nutrition labels)

Do not track. Match `Scany/PrivacyInfo.xcprivacy`:

| Data | Linked | Tracking | Purpose |
| --- | --- | --- | --- |
| Email Address | Yes | No | App Functionality (Google account label) |
| Name | Yes | No | App Functionality (Google account label) |
| User Content | Yes | No | App Functionality (scan images / PDF upload) |

Not collected: location, contacts, browsing history, identifiers for ads, purchases, health, financial info.

Used for third-party advertising / developer advertising / analytics / product personalization: **No**.

## Google Cloud (do this before submit)

1. APIs & Services → enable **Google Drive API**.
2. iOS OAuth client bundle ID must be **`com.prnysoni.Scany`** (same as the app).
3. Consent screen scopes: `drive.file` and `userinfo.email`.
4. Publishing: **In production** so customers can sign in. Testing mode only works for listed test users (use that for Apple’s demo account until production is on).
5. `drive.file` is a sensitive scope. Unverified apps show a warning and a ~100-user cap. Start Google’s verification (privacy URL + a short demo video of Drive connect → folder → upload) if you want Drive for the public, not just reviewers.
6. iCloud does not need Google verification. The app is usable App Store-wide with iCloud alone.

## Xcode archive

1. Open `Scany.xcodeproj`, scheme **Scany**, destination **Any iOS Device**.
2. Signing: Team **9M5QTLKHWQ**, Automatically manage signing, Release.
3. Product → Archive. Organizer → Distribute App → App Store Connect → Upload.
4. In App Store Connect, select build **1**, attach screenshots and the copy above, answer encryption **No** (standard HTTPS; `ITSAppUsesNonExemptEncryption` is already `NO`).
5. Submit for review.

If Archive is greyed out, pick Any iOS Device (arm64), not a Simulator.

After a successful upload, bump `CURRENT_PROJECT_VERSION` for the next binary (keep `MARKETING_VERSION` at 1.0 until you ship a 1.1).
