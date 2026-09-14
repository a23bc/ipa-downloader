import SwiftUI

/// Main tab bar — Search / Downloads / Settings.
struct MainTabView: View {
    @StateObject private var search = SearchService()
    @StateObject private var downloads = DownloadService()

    var body: some View {
        TabView {
            SearchView()
                .environmentObject(search)
                .environmentObject(downloads)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            DownloadsView()
                .environmentObject(downloads)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
