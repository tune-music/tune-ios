import SwiftUI

enum Theme {
    static let background = Color.black
    static let accent = Color("AccentColor")
    static let surface = Color(white: 0.11)
    static let raised = Color(white: 0.17)
    static let dim = Color(white: 0.6)
    static let tone = Color(white: 0.16)
}

extension Color {
    /// Цвет из строки «#3678bc», как их присылает Яндекс.
    init?(hex: String?) {
        guard let hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension View {
    /// Стеклянная подложка: Liquid Glass на iOS 26, размытие или цвет на более старых.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.legacyGlass(in: shape, tint: tint)
        }
        #else
        self.legacyGlass(in: shape, tint: tint)
        #endif
    }

    /// Дымка под часами и кнопками навигации: прокрученный список растворяется в цвете
    /// страницы и не мешает читать кнопки. Пока страница не прокручена, дымка сливается с фоном.
    func topScrim(_ color: Color) -> some View {
        overlay(alignment: .top) {
            LinearGradient(
                stops: [.init(color: color, location: 0), .init(color: color.opacity(0.9), location: 0.55), .init(color: color.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 132)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        if let tint {
            self.background(tint, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Нажатие с откликом: кнопка поджимается под пальцем и пружинит обратно.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Значок «играть / пауза»: одна фигура перетекает в другую, а не сменяется затуханием.
struct PlayGlyph: View {
    let playing: Bool
    let size: CGFloat

    var body: some View {
        let image = Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size))
        if #available(iOS 17.0, *) {
            image
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: playing)
        } else {
            image
        }
    }
}

/// Разрыв между кнопками панели навигации: на iOS 26 меню «…» получает свою стеклянную
/// кнопку и раскрывается из неё, а не из общей плашки.
@ToolbarContentBuilder
func toolbarGap() -> some ToolbarContent {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
        ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
    }
    #endif
}

private struct PickPlaylistKey: EnvironmentKey {
    static let defaultValue: (Track) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Открыть выбор плейлиста, в который добавить трек.
    var pickPlaylist: (Track) -> Void {
        get { self[PickPlaylistKey.self] }
        set { self[PickPlaylistKey.self] = newValue }
    }
}

/// Пункты меню трека: одни и те же в списках и в плеере.
struct TrackMenu: View {
    let track: Track
    var inPlayer = false
    var onRemove: (() -> Void)?
    let navigate: (Route) -> Void
    let pick: (Track) -> Void
    /// Вызывается после выбора пункта: в плеере меню показано листом, и его надо закрыть.
    var done: () -> Void = {}

    private var player: Player { Player.shared }
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session

    var body: some View {
        let liked = session.isLiked(track.id)
        let disliked = session.disliked.contains(track.id)
        Button {
            session.toggleLike(track)
            done()
        } label: {
            Label(liked ? "Убрать из «Мне нравится»" : "Нравится", systemImage: liked ? "heart.slash" : "heart")
        }
        Button {
            if inPlayer { player.dislikeCurrent() } else { session.toggleDislike(track) }
            done()
        } label: {
            Label(disliked ? "Снять дизлайк" : "Не нравится", systemImage: disliked ? "hand.thumbsup" : "hand.thumbsdown")
        }
        Button {
            done()
            pick(track)
        } label: {
            Label("Добавить в плейлист", systemImage: "text.badge.plus")
        }
        if downloads.has(track.id) {
            Button(role: .destructive) {
                downloads.remove(track.id)
                done()
            } label: {
                Label("Удалить с устройства", systemImage: "trash")
            }
        } else if !downloads.isBusy(track.id) {
            Button {
                downloads.download(track)
                done()
            } label: {
                Label("Скачать", systemImage: "arrow.down.circle")
            }
        }
        if !inPlayer {
            Button {
                player.playNext(track)
            } label: {
                Label("Играть следующим", systemImage: "text.insert")
            }
            Button {
                player.addToQueue(track)
            } label: {
                Label("В конец очереди", systemImage: "text.append")
            }
        }
        if !inPlayer { Divider() }
        if let album = track.albumId {
            Button {
                done()
                navigate(.album(album))
            } label: {
                Label("Перейти к альбому", systemImage: "square.stack")
            }
        }
        ForEach(track.artistList.filter { !$0.id.isEmpty }.prefix(3), id: \.id) { artist in
            Button {
                done()
                navigate(.artist(artist.id, artist.name))
            } label: {
                Label(artist.name, systemImage: "music.mic")
            }
        }
        Button {
            player.playWave(seeds: ["track:\(track.id)"], name: "Волна по треку «\(track.title)»")
            done()
        } label: {
            Label("Волна по треку", systemImage: "dot.radiowaves.left.and.right")
        }
        if let url = track.shareURL {
            ShareLink(item: url) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }
        if let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Убрать из плейлиста", systemImage: "minus.circle")
            }
        }
    }
}

/// Строка трека: обложка, название, исполнители, значки и меню.
struct TrackRow: View {
    let track: Track
    /// Номер в альбоме: показывается вместо обложки, она у всех треков одна.
    var number: Int?
    /// Приглушать ли трек с дизлайком. В самом списке «Не нравится» — нет.
    var fadesDisliked = true
    var onRemove: (() -> Void)?
    let action: () -> Void

    @ObservedObject fileprivate var now = Player.shared.now
    private var player: Player { Player.shared }
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @Environment(\.pickPlaylist) private var pickPlaylist

    private var dimmed: Bool {
        (track.unavailable && !track.uncensored && !downloads.has(track.id)) || (fadesDisliked && session.disliked.contains(track.id))
    }

    var body: some View {
        let playing = now.id == track.id
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 12) {
                    lead(playing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.fullTitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(playing ? Theme.accent : Color.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if track.uncensored {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                            } else if track.explicit {
                                Text("E")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .frame(width: 13, height: 13)
                                    .background(Theme.dim, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                            if downloads.has(track.id) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                            }
                            Text(track.artists.isEmpty ? track.albumTitle : track.artists)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                TrackMenu(track: track, onRemove: onRemove, navigate: navigate, pick: pickPlaylist)
            }

            if let value = downloads.active[track.id] {
                ProgressRing(value: value)
                    .frame(width: 20, height: 20)
                    .padding(.horizontal, 6)
            } else if session.isLiked(track.id) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 4)
            }
            if number != nil {
                Text(timeText(track.duration))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, 4)
            }
            Menu {
                TrackMenu(track: track, onRemove: onRemove, navigate: navigate, pick: pickPlaylist)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(Theme.dim)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 6))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if downloads.has(track.id) {
                Button(role: .destructive) {
                    downloads.remove(track.id)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            } else {
                Button {
                    downloads.download(track)
                } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                }
                .tint(Theme.accent)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext(track)
            } label: {
                Label("Далее", systemImage: "text.insert")
            }
            .tint(.indigo)
        }
    }
}

extension TrackRow {
    /// Слева обложка, а в альбоме — номер трека. У играющего трека вместо них значок.
    @ViewBuilder
    fileprivate func lead(_ playing: Bool) -> some View {
        let mark = Image(systemName: now.playing ? "waveform" : "pause.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.accent)
        if let number {
            ZStack {
                if playing {
                    mark
                } else {
                    Text("\(number)")
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(width: 30, height: 44)
        } else {
            CoverView(uri: track.cover, size: 50, corner: 8)
                .overlay {
                    if playing {
                        ZStack {
                            Color.black.opacity(0.6)
                            mark
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
        }
    }
}

/// Кольцо хода загрузки.
struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.raised, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, min(value, 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Карточка в горизонтальной ленте: альбом, плейлист или исполнитель.
struct CardView: View {
    let title: String
    let subtitle: String
    let cover: String?
    var round = false
    var size: CGFloat = 148
    /// Отметка «играет»: nil — карточка не играет, иначе — идёт ли звук.
    var playing: Bool?

    var body: some View {
        VStack(alignment: round ? .center : .leading, spacing: 4) {
            CoverView(uri: cover, size: size, corner: 14, round: round)
                .overlay(alignment: round ? .bottom : .bottomTrailing) {
                    if let playing {
                        PlayingBadge(playing: playing)
                            .padding(8)
                    }
                }
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(playing == nil ? .white : Theme.accent)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: round ? .center : .leading)
    }
}

/// Значок «играет» на карточке: жёлтый кружок с волной, на паузе — с двумя полосками.
struct PlayingBadge: View {
    let playing: Bool
    var size: CGFloat = 34

    var body: some View {
        mark
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    @ViewBuilder private var mark: some View {
        let image = Image(systemName: playing ? "waveform" : "pause.fill")
        if #available(iOS 17.0, *) {
            image.symbolEffect(.variableColor.iterative, isActive: playing)
        } else {
            image
        }
    }
}

/// Карточка полки главной: ведёт на страницу или запускает волну.
struct HomeCard: View {
    let item: HomeItem
    var size: CGFloat = 148

    @ObservedObject private var now = Player.shared.now
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate

    /// Меню по долгому нажатию на карточку.
    @ViewBuilder private var menu: some View {
        switch item {
        case .album(let card):
            let liked = session.likedAlbums.contains(card.id)
            Button {
                session.toggleAlbum(card.id)
            } label: {
                Label(liked ? "Убрать из коллекции" : "В коллекцию", systemImage: liked ? "heart.slash" : "heart")
            }
            if let url = URL(string: "https://music.yandex.ru/album/\(card.id)") {
                ShareLink(item: url) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
            }
        case .artist(let card):
            let liked = session.likedArtists.contains(card.id)
            Button {
                session.toggleArtist(card.id)
            } label: {
                Label(liked ? "Убрать из коллекции" : "В коллекцию", systemImage: liked ? "heart.slash" : "heart")
            }
            Button {
                Player.shared.playWave(seeds: ["artist:\(card.id)"], name: card.title)
            } label: {
                Label("Волна по исполнителю", systemImage: "dot.radiowaves.left.and.right")
            }
        case .playlist(let playlist):
            if !session.playlists.contains(where: { $0.id == playlist.id }) {
                let liked = session.isLiked(playlist)
                Button {
                    session.togglePlaylist(playlist)
                } label: {
                    Label(liked ? "Убрать из коллекции" : "В коллекцию", systemImage: liked ? "heart.slash" : "heart")
                }
            }
            if let url = playlist.shareURL {
                ShareLink(item: url) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
            }
        case .wave(let wave):
            Button {
                Player.shared.playWave(seeds: wave.seeds, name: wave.title)
            } label: {
                Label("Запустить заново", systemImage: "play")
            }
        }
    }

    /// nil — карточка не играет, иначе — идёт ли звук.
    private func playing(_ kind: String, _ id: String) -> Bool? {
        now.from(kind, id) ? now.playing : nil
    }

    var body: some View {
        Button {
            switch item {
            case .album(let card): navigate(.album(card.id))
            case .artist(let card): navigate(.artist(card.id, card.title))
            case .playlist(let playlist): navigate(.playlist(playlist))
            case .wave(let wave): Player.shared.tapWave(seeds: wave.seeds, name: wave.title)
            }
        } label: {
            switch item {
            case .album(let card):
                CardView(title: card.title, subtitle: card.subtitle, cover: card.cover, size: size, playing: playing("album", card.id))
            case .artist(let card):
                CardView(title: card.title, subtitle: "", cover: card.cover, round: true, size: size, playing: playing("artist", card.id))
            case .playlist(let playlist):
                CardView(title: playlist.title, subtitle: playlist.count > 0 ? plural(playlist.count, "трек", "трека", "треков") : "", cover: playlist.cover, size: size, playing: playing("playlist", playlist.id))
            case .wave(let wave):
                WaveTile(wave: wave, size: size, playing: playing("radio", wave.id))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
    }
}

/// Волна на полке: цветной круг с названием под ним.
struct WaveTile: View {
    let wave: WaveCard
    var size: CGFloat = 148
    /// nil — волна не играет, иначе — идёт ли звук.
    var playing: Bool?

    var body: some View {
        let color = Color(hex: wave.color) ?? Theme.raised
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [color, color.opacity(0.3)], center: .center, startRadius: 4, endRadius: size * 0.55))
                if let playing {
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 3)
                    PlayingBadge(playing: playing, size: 52)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            Text(wave.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(playing == nil ? .white : Theme.accent)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: size)
    }
}

/// Полка: заголовок и горизонтальная лента карточек.
struct Shelf<Content: View>: View {
    let title: String
    private let more: (() -> Void)?
    private let content: Content

    init(_ title: String, more: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.more = more
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let more {
                    Button(action: more) {
                        HStack(spacing: 3) {
                            Text("Все")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// Заглушка на пустой или не загрузившийся экран.
struct Placeholder: View {
    let icon: String
    let title: String
    var text = ""
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(Theme.dim)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Text("Повторить")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .glass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct Spinner: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(.white)
            Spacer()
        }
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Плитка вместо обложки у «Мне нравится», «Скачанного» и «Истории».
struct SymbolCover: View {
    let symbol: String
    let colors: [Color]
    let size: CGFloat
    var corner: CGFloat = 12

    static let likes = [Color(red: 1, green: 0.3, blue: 0.42), Color(red: 0.56, green: 0.2, blue: 0.95)]
    static let downloads = [Color(red: 0.2, green: 0.62, blue: 1), Color(red: 0.12, green: 0.25, blue: 0.75)]
    static let history = [Color(red: 0.2, green: 0.75, blue: 0.6), Color(red: 0.08, green: 0.35, blue: 0.45)]
    static let disliked = [Color(white: 0.42), Color(white: 0.2)]

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Круглая стеклянная кнопка со значком: скачать, перемешать.
struct RoundButton: View {
    let symbol: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Color.white)
                .frame(width: 50, height: 50)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// Главная кнопка страницы: жёлтая «Слушать».
struct PlayButton: View {
    var title = "Слушать"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(title)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Короткое сообщение сверху экрана.
struct ToastView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        ZStack {
            if let text = session.toast {
                Text(text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glass(in: Capsule())
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.toast)
        .allowsHitTesting(false)
    }
}

/// Место под мини-плеер внизу страницы.
struct MiniPlayerSpace: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        Color.clear.frame(height: player.current == nil ? 0 : 68)
    }
}

/// Плашка с текущим треком над панелью вкладок. Смахивание вверх открывает плеер,
/// в стороны — переключает трек.
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @Environment(\.openPlayer) private var openPlayer
    @State private var tone = Theme.tone
    /// Сдвиг названия под пальцем.
    @StateObject private var drag = TrackDrag()
    /// Направление жеста определяется в его начале и до конца не меняется.
    @State private var axis: Axis?

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let move = value.translation
                if axis == nil { axis = abs(move.width) > abs(move.height) ? .horizontal : .vertical }
                guard axis == .horizontal else { return }
                drag.move(move.width)
            }
            .onEnded { value in
                let locked = axis
                axis = nil
                if locked == .horizontal {
                    let far = abs(value.translation.width) > 50 || abs(value.predictedEndTranslation.width) > 160
                    // Трек переключается без общей анимации: иначе вместе с названием
                    // анимировались все строки списка под мини-плеером.
                    let ahead = value.translation.width < 0
                    drag.release {
                        guard far else { return }
                        if ahead { player.next() } else { player.previous() }
                    }
                } else if value.translation.height < -36 {
                    // Плеер открывается только явным движением вверх.
                    openPlayer()
                }
            }
    }

    var body: some View {
        if let track = player.current {
            let liked = session.isLiked(track.id)
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            HStack(spacing: 0) {
                TrackPager(style: .row, track: track, drag: drag)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        // Жесты ловит прозрачный слой поверх ленты: сама она нажатий не принимает.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: openPlayer)
                            .gesture(swipe)
                    }

                Button {
                    session.toggleLike(track)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(liked ? Theme.accent : Color.white)
                        .frame(width: 46)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    player.toggle()
                } label: {
                    PlayGlyph(playing: player.isPlaying, size: 22)
                        .foregroundStyle(.white)
                        .opacity(player.isBuffering ? 0.5 : 1)
                        .frame(width: 50)
                    .frame(maxHeight: .infinity)
                    // Нажатие ловит вся площадь кнопки, а не только сам значок.
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                MiniProgress(progress: player.progress)
                    .padding(.horizontal, 18)
                    .allowsHitTesting(false)
            }
            // Стекло лежит подложкой под кнопками и не перехватывает их нажатия.
            .background {
                Color.clear.glass(in: shape, tint: tone.opacity(0.75))
            }
            .contentShape(shape)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .task(id: track.cover) {
                let color = await ImageLoader.shared.tone(track.cover)
                withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
            }
        }
    }
}

private struct MiniProgress: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { geometry in
            let share = progress.duration > 0 ? min(max(progress.position / progress.duration, 0), 1) : 0
            Capsule()
                .fill(Color.white)
                .frame(width: geometry.size.width * share)
        }
        .frame(height: 2)
        .background(Color.white.opacity(0.18), in: Capsule())
    }
}
