import SwiftUI

/// Login screen — collects Apple ID + password, runs the SRP flow,
/// then optionally prompts for a 2FA code.
struct LoginView: View {
    @EnvironmentObject var auth: AuthService

    @State private var appleId = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var passwordVisible = false
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                headerView

                Form {
                    Section(header: Text("Apple ID")) {
                        TextField("you@example.com", text: $appleId)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    Section(header: Text("Password")) {
                        HStack {
                            if passwordVisible {
                                TextField("Password", text: $password)
                                    .textContentType(.password)
                            } else {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                            }
                            Button(passwordVisible ? "Hide" : "Show") {
                                passwordVisible.toggle()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if case .awaiting2FA(let phones) = auth.state {
                        Section(header: Text("Two-Factor Code"),
                                footer: Text(phones.isEmpty
                                             ? "Enter the code shown on your trusted Apple device."
                                             : "Trusted phone numbers: \(phones.joined(separator: ", "))")) {
                            TextField("6 digits", text: $twoFactorCode)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                        }
                    }

                    if case .failed(let msg) = auth.state {
                        Section { Text(msg).foregroundColor(.red) }
                    }
                }

                actionButton
                    .padding(.horizontal)
                    .padding(.bottom, 24)

                Spacer(minLength: 0)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationView {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.accentColor)
            Text("IPA Downloader")
                .font(.title2.bold())
            Text("Download .ipa packages from the App Store")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // First-run hint: if the anisette server URL isn't set yet, point
            // users to the Settings sheet (gear button, top-right) before they
            // can successfully sign in.
            if AnisetteHeadersProvider.shared.serverURL == nil {
                Button {
                    showingSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Configure Anisette Server in Settings before signing in")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 24)
    }

    private var actionButton: some View {
        Group {
            if case .awaiting2FA = auth.state {
                Button {
                    Task { await auth.submit2FACode(twoFactorCode) }
                } label: {
                    Text("Verify Code")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(twoFactorCode.count < 6)
            } else if auth.state == .initiating {
                ProgressView("Authenticating…")
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await auth.login(appleId: appleId, password: password) }
                } label: {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appleId.isEmpty || password.isEmpty)
            }
        }
    }
}
