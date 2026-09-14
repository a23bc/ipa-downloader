import SwiftUI

/// Settings tab — anisette server URL, account info, logout, "About".
struct SettingsView: View {
    @EnvironmentObject var auth: AuthService

    @State private var anisetteURLString: String = ""
    @State private var showLogoutConfirm = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success(receivedKeys: [String: String])
        case failure(String)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Account"),
                        footer: Text("Your password is stored in the iOS Keychain; it never leaves this device.")) {
                    if let acct = auth.account {
                        SettingsRow(label: "Apple ID", value: acct.appleId)
                        if acct.dsid != nil {
                            SettingsRow(label: "Status", value: "Signed In")
                        }
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Text("Sign Out")
                        }
                    } else {
                        Text("Not signed in").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Anisette Server"),
                        footer: Text("""
                            Run a local anisette-v3-server on your device or PC, then enter its URL here. \
                            Without it, Apple ID login will fail.

                            ⚠️ If the server is on your PC, do NOT use 127.0.0.1 — that's loopback on \
                            the iOS device. Use your PC's LAN IP, e.g. http://192.168.1.10:6969

                            Make sure Docker publishes the port: docker run -p 6969:6969 ...
                            And that the Windows Firewall allows inbound TCP to port 6969.
                            """)) {
                    TextField("http://192.168.1.10:6969", text: $anisetteURLString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save") {
                        if let url = URL(string: anisetteURLString) {
                            AnisetteHeadersProvider.shared.serverURL = url
                            testResult = nil
                        }
                    }
                    .disabled(anisetteURLString.isEmpty)

                    if let currentURL = AnisetteHeadersProvider.shared.serverURL {
                        SettingsRow(label: "Saved", value: currentURL.absoluteString)
                    }
                    if let reqURL = AnisetteHeadersProvider.shared.effectiveRequestURL {
                        SettingsRow(label: "Fetches", value: "GET \(reqURL.absoluteString)")
                    }

                    Button {
                        Task { await runAnisetteTest() }
                    } label: {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(AnisetteHeadersProvider.shared.serverURL == nil)

                    if let result = testResult {
                        switch result {
                        case .success(let headers):
                            VStack(alignment: .leading, spacing: 4) {
                                Label("OK — server reachable", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Received \(headers.count) headers")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                // Show the device fingerprint that Apple will see.
                                // If you run Test Connection twice and X-Mme-Device-Id
                                // is the SAME both times, the anisette server is using
                                // a single static device — Apple may rate-limit / 503
                                // it after a few logins. To rotate, restart the
                                // anisette container (it generates a new device on
                                // first boot, or use the v3 provisioning endpoint).
                                if let devId = headers["X-Mme-Device-Id"] {
                                    Text("Device-Id: \(devId)")
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                                if let clientInfo = headers["X-MMe-Client-Info"] {
                                    Text("Client: \(clientInfo)")
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        case .failure(let msg):
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Failed", systemImage: "xmark.octagon.fill")
                                    .foregroundColor(.red)
                                Text(msg)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Section(header: Text("iTunes Key")) {
                    if Secrets.hasRealKey {
                        Label("Configured", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not configured", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Purchases will fail until a valid iTunes key is provided in `IPADownloader/Secrets/Secrets.swift`. See README for instructions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Storage")) {
                    SettingsRow(label: "Downloads Dir", value: IPAFileManager.downloadsDirectory.lastPathComponent)
                }

                Section(header: Text("About")) {
                    SettingsRow(label: "Version", value: "1.0.0")
                    SettingsRow(label: "Min iOS", value: "15.0")
                    Link(destination: URL(string: "https://github.com/majd/ipatool")!) {
                        HStack {
                            Text("Based on ipatool")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                anisetteURLString = AnisetteHeadersProvider.shared.serverURL?.absoluteString ?? ""
            }
            .confirmationDialog("Sign out and clear all stored credentials?",
                                isPresented: $showLogoutConfirm,
                                titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { auth.logout() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Trigger an explicit fetch against the configured anisette server
    /// and surface the outcome in the UI. Used by the "Test Connection" button.
    private func runAnisetteTest() async {
        testResult = nil
        do {
            let headers = try await AnisetteHeadersProvider.shared.fetchHeaders()
            let received = headers.keys.sorted()
            // Sanity-check: confirm the critical keys arrived.
            let required = ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Mme-Device-Id"]
            let missing = required.filter { headers[$0] == nil }
            if missing.isEmpty {
                testResult = .success(receivedKeys: headers)
            } else {
                testResult = .failure("""
                    Server returned \(received.count) keys but is missing required ones:
                    \(missing.joined(separator: ", "))

                    Got: \(received.joined(separator: ", "))
                    """)
            }
        } catch AnisetteHeadersProvider.AnisetteError.serverError(let msg) {
            testResult = .failure(msg)
        } catch AnisetteHeadersProvider.AnisetteError.serverNotConfigured {
            testResult = .failure("No URL configured. Enter one above and tap Save.")
        } catch {
            testResult = .failure("Unexpected error: \(error.localizedDescription)")
        }
    }
}

/// iOS-15 compatible replacement for `LabeledContent` (which is iOS 16+).
struct SettingsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
