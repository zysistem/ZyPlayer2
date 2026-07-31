import SwiftUI

/// Google Drive connection and credentials.
struct GoogleDriveSettingsView: View {
    let library: LibraryStore
    let drive: GoogleDriveStore
    @Bindable var settings: AppSettings

    @State private var showCredentials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Google Drive").font(.title3.weight(.semibold))
                Spacer()
                if drive.isBusy { ProgressView().controlSize(.small) }

                if drive.isConnected {
                    Button("Yenile") { Task { await drive.sync(library: library) } }
                        .disabled(drive.isBusy)
                    Button("Bağlantıyı Kes") { Task { await drive.disconnect(library: library) } }
                } else {
                    Button("Bağlan") { Task { await drive.connect(library: library) } }
                        .disabled(settings.googleClientID.isEmpty || drive.isBusy)
                }
            }

            if drive.isConnected {
                Label("\(drive.accountFileCount) video kütüphaneye eklendi",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            DisclosureGroup("Google istemci bilgileri", isExpanded: $showCredentials) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google Cloud Console → Kimlik Bilgileri → OAuth istemci kimliği "
                         + "→ tür: Masaüstü uygulaması. Alınan değerleri buraya yapıştırın.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Client ID", text: $settings.googleClientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $settings.googleClientSecret)
                        .textFieldStyle(.roundedBorder)

                    Text("Yalnızca okuma izni istenir (drive.readonly). "
                         + "Yenileme jetonu Anahtar Zinciri'nde saklanır.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            if !drive.statusMessage.isEmpty {
                Text(drive.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
