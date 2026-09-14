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
                        LabeledContent("Apple ID", value: acct.appleId)
                        if acct.dsid != nil {
                            LabeledContent("Status", value: "Signed In")
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
                    LabeledContent("Downloads Dir", value: IPAFileManager.downloadsDirectory.lastPathComponent)
                }

                Section(header: Text("About")) {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Min iOS", value: "15.0")
                    Link("Based on ipatool",
                         destination: URL(string: "https://github.com/majd/ipatool")!)
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
