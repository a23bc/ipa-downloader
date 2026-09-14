import SwiftUI

/// Detail screen for a specific app — shows metadata and offers a Download button.
struct AppDetailView: View {
    let app: AppItem

    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var downloads: DownloadService
    @EnvironmentObject var search: SearchService

    @State private var selectedStorefront: Storefront = .US

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                descriptionCard
                downloadCard
            }
            .padding()
        }
        .navigationTitle(app.trackName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "storefront"),
               let sf = Storefront(rawValue: raw) {
                selectedStorefront = sf
            }
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray5))
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 6) {
                Text(app.trackName).font(.title3.bold()).lineLimit(2)
                Text(app.sellerName ?? "—").font(.subheadline).foregroundColor(.secondary)
                Text(app.bundleId).font(.caption).foregroundColor(.secondary).lineLimit(1)
                HStack {
                    if let v = app.version {
                        Tag(text: "v\(v)")
                    }
                    if let size = app.displaySize {
                        Tag(text: size)
                    }
                    if app.isFree {
                        Tag(text: "Free", color: .green)
                    } else if let price = app.formattedPrice {
                        Tag(text: price)
                    }
                }
            }
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(.headline)
            Text(app.description ?? "No description available.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download").font(.headline)

            HStack {
                Text("Storefront")
                Spacer()
                Picker("", selection: $selectedStorefront) {
                    ForEach(Storefront.allCases, id: \.self) { sf in
                        Text("\(sf.countryCode)").tag(sf)
                    }
                }
                .pickerStyle(.menu)
            }

            if !Secrets.hasRealKey {
                Label("iTunes Key not configured. Purchases will fail.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let active = downloads.activeTasks.first(where: { $0.appItem.trackId == app.trackId }) {
                DownloadProgressRow(task: active)
            } else {
                Button {
                    guard let account = auth.account else { return }
                    downloads.startDownload(app: app, account: account, storefront: selectedStorefront)
                } label: {
                    Label("Download IPA", systemImage: "arrow.down.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.account == nil)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct Tag: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

struct DownloadProgressRow: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.status.rawValue.capitalized)
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.1f%%", task.progress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ProgressView(value: task.progress)
                .progressViewStyle(.linear)
            if task.status == .failed, let err = task.error {
                Text(err).font(.caption).foregroundColor(.red)
            }
            if let url = task.localURL, task.status == .completed {
                Text("Saved to: \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
