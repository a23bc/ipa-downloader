// swift-tools-version: 5.9
import PackageDescription

/// This manifest only declares the project for `swift test` (running the
/// BigUInt / Crypto unit tests). The actual iOS app is built by XcodeGen +
/// Xcode — see `project.yml`.
let package = Package(
    name: "IPADownloader",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "IPADownloaderLib", targets: ["IPADownloaderLib"])
    ],
    targets: [
        .target(
            name: "IPADownloaderLib",
            path: "IPADownloader",
            exclude: ["App", "Features", "Resources", "Support"]
        ),
        .testTarget(
            name: "IPADownloaderTests",
            dependencies: ["IPADownloaderLib"],
            path: "Tests"
        )
    ]
)
