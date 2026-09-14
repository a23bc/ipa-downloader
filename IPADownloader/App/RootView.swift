import SwiftUI

/// Top-level router that flips between the Login screen and the main TabView
/// based on the current auth state.
struct RootView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Group {
            switch auth.state {
            case .idle, .initiating, .failed, .awaiting2FA:
                LoginView()
                    .transition(.opacity)
            case .authenticated:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: auth.state)
    }
}
