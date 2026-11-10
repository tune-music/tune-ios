import SwiftUI

/// Строка трека: обложка, название, исполнители, значки и меню.
struct TrackRow: View {
    let track: Track
    let action: () -> Void

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate

    private var dimmed: Bool {
        track.unavailable && !track.uncensored && !downloads.has(track.id)
    }

    var body: some View {
        let playing = player.current?.id == track.id
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    CoverView(uri: track.cover, size: 48)
                        .overlay {
                            if playing {
                                ZStack {
                                    Color.black.opacity(0.55)
                                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(track.fullTitle)
                                .font(.body)
                                .foregroundStyle(playing ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                            if track.uncensored {
                                Image(systemName: "lock.open.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            } else if track.explicit {
                                Text("E")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color(white: 0.3), in: RoundedRectangle(cornerRadius: 2))
                            }
                        }
                        HStack(spacing: 4) {
                            if downloads.has(track.id) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(track.artists.isEmpty ? track.albumTitle : track.artists)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let value = downloads.active[track.id] {
                ProgressView(value: value)
                    .progressViewStyle(.circular)
                    .frame(width: 22, height: 22)
            } else {
                Text(timeText(track.duration))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
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
                .tint(.accentColor)
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

    @ViewBuilder private var menu: some View {
        let liked = session.isLiked(track.id)
        Button {
            session.toggleLike(track)
        } label: {
            Label(liked ? "Убрать лайк" : "Нравится", systemImage: liked ? "heart.slash" : "heart")
        }
        if downloads.has(track.id) {
            Button(role: .destructive) {
                downloads.remove(track.id)
            } label: {
                Label("Удалить с устройства", systemImage: "trash")
            }
        } else if !downloads.isBusy(track.id) {
            Button {
                downloads.download(track)
            } label: {
                Label("Скачать", systemImage: "arrow.down.circle")
            }
        }
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
        Divider()
        if let album = track.albumId {
            Button {
                navigate(.album(album))
            } label: {
                Label("К альбому", systemImage: "square.stack")
            }
        }
        ForEach(track.artistList.filter { !$0.id.isEmpty }.prefix(3), id: \.id) { artist in
            Button {
                navigate(.artist(artist.id, artist.name))
            } label: {
                Label(artist.name, systemImage: "music.mic")
            }
        }
    }
}

/// Карточка в горизонтальной ленте: альбом, плейлист или исполнитель.
struct CardView: View {
    let title: String
    let subtitle: String
    let cover: String?
    var round = false
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: round ? .center : .leading, spacing: 6) {
            CoverView(uri: cover, size: size, corner: 10, round: round)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: round ? .center : .leading)
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button("Повторить", action: retry)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Полоса с текущим треком над панелью вкладок.
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    @Environment(\.openPlayer) private var openPlayer

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                MiniProgress(progress: player.progress)
                HStack(spacing: 12) {
                    Button(action: openPlayer) {
                        HStack(spacing: 12) {
                            CoverView(uri: track.cover, size: 40, corner: 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.fullTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(track.artists)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: player.toggle) {
                        ZStack {
                            if player.isBuffering {
                                ProgressView()
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Button(action: player.next) {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .background(.ultraThinMaterial)
        }
    }
}

private struct MiniProgress: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { geometry in
            let share = progress.duration > 0 ? min(max(progress.position / progress.duration, 0), 1) : 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * share)
        }
        .frame(height: 2)
        .background(Color(white: 0.25))
    }
}
