import SwiftUI

/// App search screen.
struct SearchView: View {
    @EnvironmentObject var search: SearchService
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var downloads: DownloadService

    @State private var query = ""
    @State private var selectedStorefront: Storefront = .US

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                storePicker

                if search.isLoading {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = search.error {
                    errorView(err)
                } else if search.results.isEmpty {
                    emptyStateView
                } else {
                    resultList
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Restore any saved storefront.
            if let raw = UserDefaults.standard.string(forKey: "storefront"),
               let sf = Storefront(rawValue: raw) {
                selectedStorefront = sf
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("App name, developer, or bundle ID",
                      text: $query,
                      onCommit: { Task { await runSearch() } })
                .submitLabel(.search)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !query.isEmpty {
                Button { query = ""; search.results = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    private var storePicker: some View {
        Picker("Storefront", selection: $selectedStorefront) {
            ForEach(Storefront.allCases, id: \.self) { sf in
                Text("\(sf.countryCode) — \(sf.displayName)").tag(sf)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .onChange(of: selectedStorefront) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "storefront")
        }
    }

    private func runSearch() async {
        await search.search(term: query, country: selectedStorefront.countryCode)
    }

    private var resultList: some View {
        List(search.results) { app in
            NavigationLink(destination: AppDetailView(app: app)
                                            .environmentObject(auth)
                                            .environmentObject(downloads)
                                            .environmentObject(search)) {
                AppRow(app: app)
            }
        }
        .listStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Search for apps")
                .font(.headline)
            Text("Enter a name above and press Search. Results will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Search failed")
                .font(.headline)
            Text(msg)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") { Task { await runSearch() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Single row in the search results list.
struct AppRow: View {
    let app: AppItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .overlay(Image(systemName: "app").foregroundColor(.secondary))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(app.trackName).font(.headline).lineLimit(1)
                Text(app.sellerName ?? "—").font(.caption).foregroundColor(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if let v = app.version {
                        Text("v\(v)").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    if let size = app.displaySize {
                        Text(size).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(app.isFree ? "Free" : (app.formattedPrice ?? ""))
                        .font(.caption2.bold())
                        .foregroundColor(app.isFree ? .green : .primary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
