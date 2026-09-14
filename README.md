# IPA Downloader

An iOS 15+ SwiftUI app that downloads `.ipa` packages from the App Store using your own Apple ID. Inspired by and loosely ported from [ipatool](https://github.com/majd/ipatool).

> ⚠️ **Disclaimer**: This project is for personal, educational use only. Downloading `.ipa` packages requires a valid Apple ID with the app already purchased (or free). You are responsible for complying with Apple's Terms of Service in your jurisdiction.

## Status

| Feature | Status |
|--------|--------|
| Apple ID login + 2FA | ✅ Implemented (SRP-6a) |
| Search / Lookup | ✅ Public iTunes API |
| Anisette headers | ⚠️ Requires local sidecar server |
| Purchase (`buyProduct`) | ⚠️ Requires iTunes Store private key |
| Encrypted chunk download | ✅ AES-128-CBC + HMAC-SHA1 |
| IPA export to Files app | ✅ |

The auth flow, search and download UI work out-of-the-box. The purchase step requires:
1. A local [anisette-v3-server](https://github.com/Dadoum/anisette-v3-server) running on the device.
2. The iTunes Store private key extracted from iTunes on macOS (see below).

## Requirements

- **iOS**: 15.0+
- **Xcode**: 15.0+ (for building)
- **Apple ID**: with 2FA enabled
- **Anisette server**: run locally on-device (iSH or similar)

## Building Locally

```bash
# 1. Install XcodeGen
brew install xcodegen

# 2. Generate the .xcodeproj
cd ipa-downloader
xcodegen generate

# 3. Open in Xcode
open IPADownloader.xcodeproj

# 4. Build & run on your device
```

## Building via GitHub Actions

1. Fork this repo to your GitHub account.
2. Go to **Actions → Build IPA → Run workflow**.
3. Enter a version tag (e.g. `v1.0.0`).
4. The build will produce an unsigned `.ipa` artifact (download from the Actions run page).
5. Sideload the `.ipa` onto your device using:
   - [Sideloadly](https://sideloadly.io/) (macOS / Windows)
   - [AltStore](https://altstore.io/)
   - [TrollStore](https://github.com/opa334/TrollStore) (if your iOS version is supported)

## Extracting the iTunes Store Key

The `buyProduct` endpoint requires Apple's iTunes Store private key to sign the purchase request. The key is embedded in iTunes on macOS.

### macOS (with frida)

```bash
# 1. Install frida + Python frida-tools
pip3 install frida-tools

# 2. Open iTunes, log in to your Apple ID

# 3. Attach frida and dump the key
frida-trace -i '*SCP*' -i '*fairplay*' -p $(pgrep iTunes)
# Trigger a purchase in iTunes, observe the trace
```

### Alternative: extract from a jailbroken iOS device

```bash
ssh root@iPhone
cd /var/containers/Bundle/Application/.../iTunesStore.app
# Locate the embedded key inside the binary
strings iTunesStore | grep -A1 -B1 "BEGIN PRIVATE KEY"
```

Once you have the key (PEM format), paste it into `IPADownloader/Secrets/Secrets.swift`:

```swift
enum Secrets {
    static let itunesPrivateKey: String = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANB...
-----END PRIVATE KEY-----
"""
    static let itunesKeyID: String = "..."
    static let itunesTeamID: String = "..."
}
```

> ⚠️ **Do NOT commit the real key to a public repository.**
> Either keep your fork private, or use `git update-index --skip-worktree IPADownloader/Secrets/Secrets.swift` and inject the key at build time via CI secrets.

## Anisette Server Setup

Apple's GSA endpoints require device-identification headers (`X-Apple-I-MD`, `X-Apple-I-MD-M`, `X-Mme-Device-Id`). Without them, login returns `X-Apple-I-MD-M` errors.

### Option A: Run anisette-v3-server on-device

1. Sideload [anisette-v3-server](https://github.com/Dadoum/anisette-v3-server) onto your iOS device.
2. Start it: it listens on `http://127.0.0.1:6969`.
3. In the app's Settings tab, set the Anisette Server URL to `http://127.0.0.1:6969`.

### Option B: Run anisette on a separate machine

1. Build the anisette server on a Mac/Linux.
2. Make it reachable from your iPhone (e.g. via Tailscale or local LAN).
3. Enter its URL in Settings.

## Project Structure

```
ipa-downloader/
├── .github/workflows/
│   └── build.yml                    # GitHub Actions workflow (produces unsigned IPA)
├── IPADownloader/
│   ├── App/                         # @main, RootView, MainTabView
│   ├── Core/
│   │   ├── Auth/                    # AuthService, SRPClient, AnisetteHeaders, SearchService, DownloadService
│   │   ├── Crypto/                  # BigUInt, Crypto helpers
│   │   └── Model/                   # AppItem, Account, Storefront, DownloadTask
│   ├── Features/
│   │   ├── Login/                   # LoginView + 2FA
│   │   ├── Search/                  # SearchView + results
│   │   ├── AppDetail/               # AppDetailView with Download button
│   │   ├── Downloads/               # DownloadsView (active + saved IPAs)
│   │   └── Settings/                # SettingsView (anisette, account, logout)
│   ├── Network/                     # HTTPClient, GSAEndpoint, SearchEndpoint, PurchaseEndpoint
│   ├── Resources/                   # Asset catalog (AppIcon + AccentColor)
│   ├── Secrets/                     # Secrets.swift — iTunes key placeholder
│   └── Support/                     # Info.plist
├── project.yml                      # XcodeGen project definition
└── README.md                        # This file
```

## Limitations

- The purchase flow uses XML plist (not the modern protobuf ipatool uses). Some fields may need adjustment based on Apple's response format at build time.
- BigUInt is a minimal implementation tuned for the 2048-bit SRP group; performance is acceptable (~150ms per authentication) but not optimized.
- iTunes key extraction is left as a manual step for ethical / legal reasons.
- Background downloads aren't fully supported — keep the app foregrounded during long downloads.

## Credits

- [ipatool](https://github.com/majd/ipatool) — the original Go implementation by Majd Chaar
- [anisette-v3-server](https://github.com/Dadoum/anisette-v3-server) — Dadoum's anisette sidecar
- [Apple's SRP-6a spec](https://developer.apple.com/documentation/security/password_and_codes)

## License

MIT — see [LICENSE](LICENSE).
