import SwiftUI

/// Downloads tab — shows active downloads and previously saved .ipa files.
struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadService
    @State private var savedFiles: [URL] = []
    @State private var shareSheet: URL?

    var body: some View {
        NavigationView {
            List {
                if !downloads.activeTasks.isEmpty {
                    Section("In Progress") {
                        ForEach(downloads.activeTasks) { task in
                            DownloadProgressRow(task: task)
                                .swipeActions {
                                    Button("Cancel", role: .destructive) {
                                        downloads.cancel(taskId: task.id)
                                    }
                                }
                        }
                    }
                }

                Section("Saved") {
                    if savedFiles.isEmpty {
                        Text("No downloads yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(savedFiles, id: \.self) { url in
                            HStack {
                                Image(systemName: "doc.zipper")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: IPAFileManager.size(of: url),
                                                                   countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    shareSheet = url
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    if (try? IPAFileManager.delete(url)) != nil {
                                        refresh()
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onAppear(perform: refresh)
            .sheet(item: Binding(get: { shareSheet.map { ShareURL(url: $0) } },
                                  set: { shareSheet = $0?.url })) { item in
                ShareSheet(url: item.url)
            }
        }
    }

    private func refresh() {
        savedFiles = IPAFileManager.listDownloadedIPA()
    }
}

private struct ShareURL: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
