import SwiftUI

/// Network share management: add, list, remove.
struct SMBSettingsView: View {
    let library: LibraryStore
    let smb: SMBStore

    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if smb.shares.isEmpty {
                HStack {
                    Text("NAS ya da ağdaki bir paylaşımı ekleyin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Paylaşım Ekle…") { isAdding = true }
                        .controlSize(.small)
                }
            } else {
                ForEach(smb.shares) { share in
                    SettingsRow(
                        symbol: share.isMounted ? "externaldrive.badge.checkmark" : "externaldrive.badge.xmark",
                        symbolColor: share.isMounted ? .green : .secondary,
                        title: share.displayName,
                        detail: share.isMounted ? (share.mountPath ?? "") : "Bağlı değil"
                    ) {
                        Button {
                            smb.remove(share, library: library)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Spacer()
                    Button("Paylaşım Ekle…") { isAdding = true }
                        .controlSize(.small)
                }
            }

            if !smb.statusMessage.isEmpty {
                Text(smb.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isAdding) {
            AddShareSheet(library: library, smb: smb, isPresented: $isAdding)
        }
    }
}

private struct AddShareSheet: View {
    let library: LibraryStore
    let smb: SMBStore
    @Binding var isPresented: Bool

    @State private var host = ""
    @State private var shareName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isGuest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ağ Paylaşımı Ekle").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Sunucu")
                    TextField("192.168.1.10 ya da nas.local", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Paylaşım")
                    TextField("Movies", text: $shareName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("")
                    Toggle("Misafir olarak bağlan", isOn: $isGuest)
                }
                if !isGuest {
                    GridRow {
                        Text("Kullanıcı")
                        TextField("", text: $username)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Parola")
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Text("Parola macOS Anahtar Zinciri'nde saklanır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Vazgeç") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Bağlan") {
                    Task {
                        let ok = await smb.add(
                            host: host, shareName: shareName,
                            username: username, password: password,
                            isGuest: isGuest, library: library
                        )
                        if ok { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || shareName.isEmpty || smb.isBusy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
