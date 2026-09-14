import SwiftUI

/// Settings tab — anisette server URL, account info, logout, "About".
struct SettingsView: View {
    @EnvironmentObject var auth: AuthService

    @State private var anisetteURLString: String = ""
    @State private var showLogoutConfirm = false

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
                        footer: Text("Run a local anisette-v3-server on your device, then enter its URL here. Without it, Apple ID login will fail.")) {
                    TextField("http://127.0.0.1:6969", text: $anisetteURLString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save") {
                        if let url = URL(string: anisetteURLString) {
                            AnisetteHeadersProvider.shared.serverURL = url
                        }
                    }
                    .disabled(anisetteURLString.isEmpty)

                    if let currentURL = AnisetteHeadersProvider.shared.serverURL {
                        SettingsRow(label: "Current", value: currentURL.absoluteString)
                    }

                    // Quick-link to the anisette-v3-server project for the user
                    // to learn how to obtain / run it on-device.
                    Link(destination: URL(string: "https://github.com/Dadoum/anisette-v3-server")!) {
                        HStack {
                            Image(systemName: "link.circle")
                                .foregroundColor(.accentColor)
                            Text("Get anisette-v3-server →")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
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
