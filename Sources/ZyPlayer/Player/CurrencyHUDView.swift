import SwiftUI
import Foundation

/// Truncgil'in ücretsiz uçundan döviz/altın kurları çeker. Player'daki HUD
/// bunu 'S' tuşuyla açıp kapatıyor; tuş burada değil `BluetoothRemoteManager`'da
/// yönetiliyor çünkü klavye/kumanda olayları hep oradan geçiyor.
@Observable
final class CurrencyHUDModel {
    struct Item: Identifiable {
        var id: String
        var title: String
        var price: String
        var changePercent: Double
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Sırayla denenen anahtarlar: Truncgil'in JSON'u aynı kalemi zaman zaman
    /// tireli, boşluklu ya da Türkçe başlıklı verebiliyor.
    private static let configs: [(key: String, apiKeys: [String])] = [
        ("USD", ["USD"]),
        ("EUR", ["EUR"]),
        ("GBP", ["GBP"]),
        ("ALTIN", ["gram-altin", "gram altin", "Gram Altın", "GRAM ALTIN"]),
        ("TAM", ["tam-altin", "tam altin", "Tam Altın", "TAM ALTIN"]),
        ("GÜMÜŞ", ["gumus", "Gümüş", "GUMUS"])
    ]

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    private func refresh() async {
        guard let url = URL(
            string: "https://finans.truncgil.com/today.json?t=\(Int(Date().timeIntervalSince1970))"
        ) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        items = Self.configs.compactMap { config in
            for apiKey in config.apiKeys {
                if let raw = json[apiKey] as? [String: Any] {
                    return Self.makeItem(key: config.key, raw: raw)
                }
            }
            return nil
        }
    }

    private static func makeItem(key: String, raw: [String: Any]) -> Item? {
        let rawPrice = (raw["Satış"] as? String) ?? (raw["Satis"] as? String)
            ?? (raw["Alış"] as? String) ?? (raw["Alis"] as? String)
        let changeStr = (raw["Değişim"] as? String) ?? (raw["Degisim"] as? String) ?? "0"
        return Item(id: key, title: key,
                    price: parsePrice(rawPrice),
                    changePercent: parseChange(changeStr))
    }

    private static func parsePrice(_ raw: String?) -> String {
        guard let raw else { return "···" }
        let normalized = raw.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return "···" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "···"
    }

    private static func parseChange(_ raw: String) -> Double {
        let cleaned = raw.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned) ?? 0
    }
}

/// Player'ın sağ üstünde beliren döviz/altın paneli — kontrol çubuğuyla aynı
/// buğulu cam görünümde (`.ultraThinMaterial` + ince beyaz kenarlık + yumuşak
/// gölge), 'S' tuşuyla açılıp kapanıyor.
struct CurrencyHUDView: View {
    @State private var model = CurrencyHUDModel()
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM EEE"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            clock
            if !model.items.isEmpty {
                divider
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    currencyColumn(item)
                    if index < model.items.count - 1 { divider }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 11, y: 4)
        .onReceive(clockTimer) { now = $0 }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.timeFormatter.string(from: now))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.numericText())
            Text(Self.dateFormatter.string(from: now).uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.7)
        }
        .padding(.trailing, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 10)
    }

    private func currencyColumn(_ item: CurrencyHUDModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(item.title)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(0.3)
                Text("\(item.changePercent >= 0 ? "▲" : "▼")\(String(format: "%.2f", abs(item.changePercent)))%")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(item.changePercent >= 0 ? .green : .red)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("₺")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                Text(item.price)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
    }
}
