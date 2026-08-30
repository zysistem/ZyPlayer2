import SwiftUI

/// Sağ alt köşede duran "fikir sor" sohbet kutusu. Kütüphane + ZyStream +
/// Netflix/Prime + sinema/Apple TV kataloglarından, izleme geçmişine göre
/// NVIDIA NIM'e soru sorup öneri alıyor. Oynatıcı açıkken RootView bu widget'ı
/// hiç göstermiyor.
struct ChatAssistantView: View {
    let library: LibraryStore
    let stream: ZyStreamStore
    let providers: StreamingProviderStore
    let cinema: CinemaStore
    let appleTV: AppleTVStore
    let settings: AppSettings
    let actions: LibraryActions
    let onOpenStream: (StreamHit) -> Void
    let chat: ChatAssistantStore

    @State private var isOpen = false
    @State private var input = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isOpen {
                panel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toggleButton
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isOpen.toggle()
            }
            if isOpen { isInputFocused = true }
        } label: {
            Image(systemName: isOpen ? "chevron.down" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .frame(width: 360, height: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Film/Dizi Asistanı").font(.system(size: 14, weight: .semibold))
            Spacer()
            if !chat.messages.isEmpty {
                Button("Temizle") { chat.clear() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty {
                        Text("Ne izlesem diye mi düşünüyorsun? Sor, kütüphanene ve " +
                             "izleme geçmişine göre öneririm.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }
                    ForEach(chat.messages) { message in
                        messageBubble(message).id(message.id)
                    }
                    if chat.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Düşünüyor…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == .user ? Color.accentColor : Color.gray.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 12)
                )

            if !message.referencedCandidateIDs.isEmpty {
                let refs = message.referencedCandidateIDs.compactMap { id in
                    poolCandidates.first { $0.id == id }
                }.prefix(6)
                if !refs.isEmpty {
                    // 3'erli iki sıra (3+3), en fazla 6 kart — sohbet panosunun
                    // dar genişliğine sığması için ana ekrandaki yatay kaydırmalı
                    // şeritten farklı olarak sabit bir grid kullanılıyor.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                              alignment: .leading, spacing: 10) {
                        ForEach(Array(refs), id: \.id) { candidate in
                            CandidateCardView(candidate: candidate, library: library, stream: stream,
                                               actions: actions, onOpenStream: onOpenStream)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 14)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Bir şey sor…", text: $input)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit(sendMessage)
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        input.trimmingCharacters(in: .whitespaces).isEmpty
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || chat.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Sohbetin önerebileceği KAPALI aday havuzu — mesaj balonlarındaki
    /// referansları gerçek karta çevirmek için de kullanılıyor.
    private var poolCandidates: [RecommendationCandidate] {
        RecommendationPoolBuilder.build(library: library, stream: stream, providers: providers,
                                         cinema: cinema, appleTV: appleTV).candidates
    }

    private func sendMessage() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !chat.isLoading else { return }
        input = ""
        let pool = RecommendationPoolBuilder.build(library: library, stream: stream, providers: providers,
                                                    cinema: cinema, appleTV: appleTV)
        Task {
            await chat.send(text, watched: pool.watched, candidates: pool.candidates,
                             apiKey: settings.nvidiaApiKey)
        }
    }
}
