# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x on the App Store | Yes |
| Older TestFlight or local builds | No |

## Reporting a vulnerability

Email [prnysoni@gmail.com](mailto:prnysoni@gmail.com). Please do not open
a public issue for a security report.

Include the iOS version, the device, and enough detail to reproduce the
problem. You will get a reply within 7 days. If the report is valid, the
fix ships in the next App Store build, and you will be credited unless
you ask not to be.

## Out of scope

The iOS OAuth client ID in `Scany/Cloud/CloudConfig.swift` is public by
design. Google restricts it to the app’s bundle ID. A client secret is
not used and should never be sent to this project.
