import SwiftUI

/// Запись списка изменений: что появилось в очередной пачке.
struct Change: Codable, Identifiable {
    var date: String
    var title: String
    var items: [String]

    var id: String { date + title }

    /// Список лежит в приложении: его же сборка кладёт в источник обновлений.
    static let all: [Change] = {
        guard let url = Bundle.main.url(forResource: "changes", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([Change].self, from: data)) ?? []
    }()

    /// «2026-11-13» → «13 ноября».
    var day: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let value = parser.date(from: date) else { return date }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = "d MMMM"
        return out.string(from: value)
    }
}

/// «Что нового»: изменения по пачкам, свежие сверху.
struct ChangesScreen: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Change.all) { change in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(change.day.uppercased())
                            .font(.scaled(size: 12, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(Theme.dim)
                        Text(change.title)
                            .font(.scaled(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(change.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle()
                                        .fill(Theme.accent)
                                        .frame(width: 5, height: 5)
                                        .offset(y: -3)
                                    Text(item)
                                        .font(.scaled(size: 15))
                                        .foregroundStyle(Theme.text.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                if Change.all.isEmpty {
                    Placeholder(icon: "sparkles", title: "Список изменений пуст")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Что нового")
        .navigationBarTitleDisplayMode(.inline)
    }
}
