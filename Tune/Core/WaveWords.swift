import Foundation

/// Подсказка колеса волны: другая волна, альбом или «Настроить Мою волну».
struct WheelItem: Identifiable, Hashable {
    enum Action: Hashable {
        case wave([String])
        case album(String)
        case setting
    }

    /// Тип и номер, как их ждёт Яндекс в отзывах: WAVE и mood:sad.
    var kind: String
    var id: String
    var action: Action
    var title: String
    var subtitle: String
    var cover: String?
    var color: String?
}

/// Карточка «Слов в волне»: короткий факт о треке и, если есть, рассказ подробнее.
struct WordCard: Hashable {
    var id: String
    var text: String
    var big: String?
    /// like, dislike или neutral.
    var feedback: String
}

/// Подробный рассказ к карточке и ссылка «Обсудить с Алисой AI».
struct WordBig: Hashable {
    var text: String
    var actionTitle: String?
    var actionURL: URL?
}

/// Колесо волны, как в Tune Native: подсказки волн по настроению, жанру и артистам к тому,
/// что играет. Отзывы о прошлом колесе (что показали и что нажали) уходят со следующим запросом.
@MainActor
final class WaveWheel: ObservableObject {
    static let shared = WaveWheel()
    /// Сколько первых подсказок считаются показанными.
    private static let seen = 6

    @Published private(set) var items: [WheelItem] = []
    private var wheelId: String?
    private var key: [String]?
    private var feedbacks: [[String: Any]] = []

    /// Колесо к играющей волне; без волны — к «Моей волне».
    func load(seeds: [String]) {
        guard Settings.waveWheel, !Demo.on, key != seeds else { return }
        key = seeds
        let sent = feedbacks
        feedbacks = []
        Task {
            do {
                let (id, items) = try await API.shared.wheel(seeds: seeds, feedbacks: sent)
                guard self.key == seeds else { return }
                self.wheelId = id
                // Подсказки на экране сразу видны: о них Яндекс узнает со следующим колесом.
                for (position, item) in items.prefix(Self.seen).enumerated() {
                    self.feedbacks.append(Self.feedback(id, "VIEW", item, position))
                }
                self.items = items
            } catch {
                self.key = nil
                Log.shared.add("колесо волны: \(error.localizedDescription)")
            }
        }
    }

    /// Нажали на подсказку. Подсказка, которая ничего не включает, отправляет отзывы сразу.
    func clicked(_ item: WheelItem) {
        guard let wheelId, let position = items.firstIndex(of: item) else { return }
        feedbacks.append(Self.feedback(wheelId, "CLICK", item, position))
        if item.action == .setting {
            let sent = feedbacks
            feedbacks = []
            Task.detached(priority: .utility) { try? await API.shared.wheelFeedbacks(sent) }
        }
    }

    private static func feedback(_ wheel: String, _ event: String, _ item: WheelItem, _ position: Int) -> [String: Any] {
        ["wheelId": wheel, "timestamp": Int(Date().timeIntervalSince1970 * 1000), "eventType": event,
         "item": ["type": item.kind, "id": item.id], "position": position]
    }
}

/// «Слова в волне», как в Tune Native: короткие факты о треках от ИИ Яндекса.
@MainActor
final class WaveWords: ObservableObject {
    static let shared = WaveWords()
    /// К скольким трекам вперёд просить карточки.
    private static let ahead = 10
    static let loading = ["Изучаю звучание", "Настраиваюсь", "Собираю интересное силой ИИ", "Читаю про артиста", "Ловлю ритм"]

    /// Номер трека → карточка.
    @Published private(set) var cards: [String: WordCard] = [:]
    /// Номер карточки → рассказ подробнее.
    @Published private(set) var bigs: [String: WordBig] = [:]
    private var asked: Set<String> = []
    private var viewed: [String] = []
    private var viewedBig: [(String, [String])] = []

    func reset() {
        cards = [:]
        asked = []
    }

    /// Просит карточки к ближайшим трекам. У своих загруженных треков карточек нет.
    func load(queue: [Track], from index: Int) {
        guard Settings.waveWords, !Demo.on, queue.indices.contains(index) else { return }
        let ids = queue[index...].prefix(Self.ahead).filter { !$0.isPrivate && !asked.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        asked.formUnion(ids)
        let seen = viewed
        let seenBig = viewedBig
        viewed = []
        viewedBig = []
        Task {
            do {
                let found = try await API.shared.wordsCards(trackIds: ids, viewed: seen, viewedBig: seenBig)
                self.cards.merge(found) { _, new in new }
            } catch {
                // Не загрузились — спросим ещё раз со следующей порцией волны.
                self.asked.subtract(ids)
            }
        }
    }

    /// Карточка трека видна на экране волны: Яндексу скажем, что её уже показали.
    func shown(_ track: Track) {
        guard let card = cards[track.id], !viewed.contains(card.id) else { return }
        viewed.append(card.id)
    }

    /// Рассказ подробнее к карточке трека.
    func big(for track: Track) async throws -> WordBig? {
        guard let card = cards[track.id], let big = card.big else { return nil }
        if let ready = bigs[card.id] { return ready }
        if !viewedBig.contains(where: { $0.0 == card.id }) { viewedBig.append((card.id, [big])) }
        let story = try await API.shared.wordsBig(big: big, track: track.id, card: card.id)
        bigs[card.id] = story
        return story
    }

    /// «Больше такого» и «Мимо»; повторное нажатие снимает оценку.
    func rate(_ track: Track, _ state: String) {
        guard var card = cards[track.id] else { return }
        let before = card.feedback
        let value = before == state ? "neutral" : state
        card.feedback = value
        cards[track.id] = card
        if value == "like" { Session.shared.show("Спасибо за оценку") }
        if value == "dislike" { Session.shared.show("Спасибо, что помогаете мне стать лучше") }
        Task {
            do {
                try await API.shared.wordsFeedback(card: card.id, state: value)
            } catch {
                self.cards[track.id]?.feedback = before
                Session.shared.show("Не удалось отправить оценку")
            }
        }
    }
}
