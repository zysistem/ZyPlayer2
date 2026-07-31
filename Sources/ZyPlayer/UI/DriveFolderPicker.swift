import SwiftUI

/// Browse Drive folders and pick the one to index.
struct DriveFolderPicker: View {
    let drive: GoogleDriveStore
    @Bindable var settings: AppSettings
    let library: LibraryStore
    let onDone: () -> Void

    /// Breadcrumb from My Drive down to the folder being shown.
    @State private var path: [(id: String, name: String)] = [("root", "Drive'ım")]
    @State private var folders: [GoogleDriveClient.DriveFile] = []
    @State private var isLoading = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drive Klasörü Seç").font(.headline)

            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button(entry.name) {
                        path = Array(path.prefix(index + 1))
                        Task { await load() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty {
            Text(message.isEmpty ? "Bu klasörde alt klasör yok." : message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        Button {
                            path.append((folder.id, folder.name))
                            Task { await load() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tint)
                                Text(folder.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Seçili: \(path.last?.name ?? "-")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Vazgeç", action: onDone)
                .keyboardShortcut(.cancelAction)
            Button("Bu Klasörü Kullan") {
                guard let current = path.last else { return }
                settings.driveFolderID = current.id
                settings.driveFolderName = current.name
                onDone()
                Task { await drive.sync(library: library) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func load() async {
        guard let current = path.last else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await drive.folders(in: current.id)
            message = ""
        } catch {
            folders = []
            message = error.localizedDescription
        }
    }
}
