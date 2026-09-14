import Foundation

/// Placeholder for Apple's iTunes Store private key.
///
/// ⚠️  In a production fork:
///   1. Replace the empty `privateKey` below with the real key extracted from
///      iTunes on macOS (see README.md → "Extracting iTunes Key").
///   2. NEVER commit the real key to a public repo.
///   3. For a self-hosted fork, store it in `git stash` or load it via
///      an environment variable injected by GitHub Actions.
///
/// For development, leaving this empty causes purchase requests to fail at
/// the server side — but search and authentication still work, which is
/// enough for UI development.
enum Secrets {
    /// iTunes Store private key (PEM-encoded).
    /// Leave empty in the public repo; replace before building for sideloading.
    static let itunesPrivateKey: String = ""

    /// iTunes Store key ID (decimal integer, as used by ipatool).
    static let itunesKeyID: String = ""

    /// iTunes Store "magic" team identifier.
    static let itunesTeamID: String = ""

    static var hasRealKey: Bool { !itunesPrivateKey.isEmpty }
}
