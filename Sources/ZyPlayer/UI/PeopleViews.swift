import SwiftUI

/// Circular portrait with a name under it. Used on detail screens and in search
/// results, so a person looks the same wherever they turn up.
struct PersonCard: View {
    let person: PersonRef
    var size: CGFloat = 84
    let onSelect: (PersonRef) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect(person)
        } label: {
            VStack(spacing: 6) {
                portrait
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(
                            .white.opacity(isHovering ? 0.95 : 0.1),
                            lineWidth: isHovering ? 2 : 1
                        )
                    )

                Text(person.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: size + 24)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scaleEffect(isHovering ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .help(person.name)
    }

    @ViewBuilder
    private var portrait: some View {
        if let url = person.profileURL {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(person.initials)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// A horizontal strip of people with paging arrows.
///
/// A cast list runs to twenty names, far past the window's width, and a
/// horizontal scroll view gives no hint that there is more — so the row carries
/// its own back/forward buttons.
struct PeopleStrip: View {
    var title: String = "Oyuncular ve Ekip"
    /// Shown next to the title when set, e.g. the number of search hits.
    var count: Int?
    let people: [PersonRef]
    let onSelect: (PersonRef) -> Void

    /// The person pinned to the left edge; nil means the start.
    @State private var anchor: Int?

    /// How many cards a click moves. Roughly a screenful at the usual width.
    private let step = 5

    private var currentIndex: Int {
        people.firstIndex { $0.id == anchor } ?? 0
    }

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if let count {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if people.count > step {
                        pageButton("chevron.left", delta: -step,
                                   isDisabled: currentIndex == 0)
                        pageButton("chevron.right", delta: step,
                                   isDisabled: currentIndex >= people.count - 1)
                    }
                }
                .padding(.horizontal, 24)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(people) { person in
                            PersonCard(person: person, onSelect: onSelect)
                                .id(person.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 2)
                }
                .scrollPosition(id: $anchor, anchor: .leading)
            }
        }
    }

    private func pageButton(_ systemImage: String, delta: Int, isDisabled: Bool) -> some View {
        Button {
            let target = min(max(currentIndex + delta, 0), people.count - 1)
            withAnimation(.easeOut(duration: 0.25)) { anchor = people[target].id }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
                .background(.white.opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.3 : 1)
    }
}

/// A person's own screen: portrait, biography, and everything they were in.
struct PersonDetailView: View {
    let person: PersonRef
    let library: LibraryStore
    let settings: AppSettings
    let onBack: () -> Void
    let onSelectTitle: (RemoteTitle) -> Void

    @State private var loader = PersonFilmographyLoader()
    @State private var isBiographyExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if loader.isLoading && loader.titles.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if loader.titles.isEmpty {
                    Text("Bu kişi için içerik bulunamadı.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                } else {
                    Text("Yer Aldığı Yapımlar")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                    PosterGrid(items: loader.titles) { title, isGamepadSelected in
                        RemoteCard(
                            title: title,
                            isOwned: isOwned(title),
                            onSelect: { onSelectTitle(title) },
                            isGamepadSelected: isGamepadSelected
                        )
                    }
                }
            }
        }
        .task(id: person.id) {
            await loader.load(person, settings: settings)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(9)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)

            portrait
                .frame(width: 132, height: 132)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(radius: 10)

            VStack(alignment: .leading, spacing: 8) {
                Text(loader.detail?.name ?? person.name)
                    .font(.system(size: 26, weight: .bold))

                if let line = subtitleLine, !line.isEmpty {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let biography = loader.detail?.biography, !biography.isEmpty {
                    Text(biography)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(isBiographyExpanded ? nil : 4)
                        .frame(maxWidth: 720, alignment: .leading)

                    Button(isBiographyExpanded ? "Daha az" : "Devamını oku") {
                        withAnimation(.easeOut(duration: 0.15)) { isBiographyExpanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private var subtitleLine: String? {
        var parts: [String] = []
        if let department = loader.detail?.knownForDepartment ?? person.department {
            parts.append(Self.departmentName(department))
        }
        if let place = loader.detail?.placeOfBirth, !place.isEmpty { parts.append(place) }
        if !loader.titles.isEmpty { parts.append("\(loader.titles.count) yapım") }
        return parts.joined(separator: " · ")
    }

    private func isOwned(_ title: RemoteTitle) -> Bool {
        switch title.kind {
        case .movie: library.movie(tmdbID: title.tmdbID) != nil
        case .tv:    library.seriesKey(tmdbID: title.tmdbID) != nil
        }
    }

    @ViewBuilder
    private var portrait: some View {
        let url = (loader.detail?.profilePath).map { TMDBClient.imageURL(path: $0, size: "h632") }
            ?? person.largeProfileURL
        if let url {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    portraitPlaceholder
                }
            }
        } else {
            portraitPlaceholder
        }
    }

    private var portraitPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(person.initials)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    static func departmentName(_ department: String) -> String {
        switch department {
        case "Acting": "Oyuncu"
        case "Directing": "Yönetmen"
        case "Writing": "Senarist"
        case "Production": "Yapımcı"
        case "Sound": "Müzik"
        case "Camera": "Görüntü Yönetmeni"
        default: department
        }
    }
}
