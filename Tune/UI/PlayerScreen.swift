import AVKit
import SwiftUI

/// Полноэкранный плеер: открывается шторкой поверх вкладок.
struct PlayerScreen: View {
    private enum Panel: String, Identifiable {
        case queue, lyrics
        var id: String { rawValue }
    }

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?

    var body: some View {
        GeometryReader { geometry in
            let side = max(120, min(geometry.size.width - 56, geometry.size.height * 0.46))
            VStack(spacing: 0) {
                top
                Spacer(minLength: 12)
                CoverView(uri: player.current?.cover, size: side, corner: 16)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                Spacer(minLength: 12)
                if let track = player.current {
                    titles(track)
                    SeekBar(progress: player.progress) { player.seek(to: $0) }
                        .padding(.top, 14)
                    controls
                        .padding(.top, 10)
                    bottom(track)
                        .padding(.top, 18)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .sheet(item: $panel) { panel in
            switch panel {
            case .queue:
                QueueSheet()
            case .lyrics:
                if let track = player.current {
                    LyricsSheet(track: track, progress: player.progress)
                }
            }
        }
        .onChange(of: player.current == nil) { empty in
            if empty { dismiss() }
        }
    }

    private var top: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            Spacer()
            Text(player.contextName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            RoutePicker()
                .frame(width: 40, height: 40)
        }
        .foregroundStyle(.primary)
    }

    private func titles(_ track: Track) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.fullTitle)
                        .font(.title3.bold())
                        .lineLimit(1)
                    if track.uncensored {
                        Image(systemName: "lock.open.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(track.artists)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let liked = session.isLiked(track.id)
            Button {
                session.toggleLike(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(liked ? Color.accentColor : Color.primary)
                    .frame(width: 44, height: 44)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 56, height: 56)
            }
            Spacer()
            Button(action: player.toggle) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    if player.isBuffering {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 72, height: 72)
            }
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 56, height: 56)
            }
            Spacer()
            Button(action: player.cycleRepeat) {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.primary)
    }

    private func bottom(_ track: Track) -> some View {
        HStack {
            Button {
                panel = .lyrics
            } label: {
                Image(systemName: "quote.bubble")
                    .frame(width: 44, height: 44)
            }
            .disabled(!track.hasLyrics)
            Spacer()
            if let value = downloads.active[track.id] {
                ProgressView(value: value)
                    .progressViewStyle(.circular)
                    .frame(width: 44, height: 44)
            } else if downloads.has(track.id) {
                Button {
                    downloads.remove(track.id)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                }
            } else {
                Button {
                    downloads.download(track)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 44, height: 44)
                }
            }
            Spacer()
            Button {
                panel = .queue
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 44, height: 44)
            }
        }
        .font(.title3)
        .foregroundStyle(.primary)
    }
}

/// Полоса перемотки: пока палец на ней, позиция трека её не двигает.
private struct SeekBar: View {
    @ObservedObject var progress: PlaybackProgress
    let seek: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let length = max(progress.duration, 1)
        let value = min(drag ?? progress.position, length)
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { value }, set: { drag = $0 }),
                in: 0...length,
                onEditingChanged: { editing in
                    if !editing, let target = drag {
                        seek(target)
                        drag = nil
                    }
                })
            HStack {
                Text(timeText(value))
                Spacer()
                Text(timeText(progress.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// Системная кнопка выбора колонки или наушников (AirPlay, Bluetooth).
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(named: "AccentColor")
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct QueueSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                        Button {
                            player.jump(to: index)
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(uri: track.cover, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.fullTitle)
                                        .foregroundStyle(index == player.index ? Color.accentColor : Color.primary)
                                        .lineLimit(1)
                                    Text(track.artists)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if index == player.index {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            }
            .navigationTitle(player.contextName.isEmpty ? "Очередь" : player.contextName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct LyricsSheet: View {
    let track: Track
    @ObservedObject var progress: PlaybackProgress
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [LyricLine]?

    /// Строка, которая сейчас звучит. У текста без времени её нет.
    private var active: Int? {
        guard let lines else { return nil }
        return lines.last { line in
            guard let time = line.time else { return false }
            return time <= progress.position + 0.25
        }?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if let lines {
                    if lines.isEmpty {
                        Placeholder(icon: "quote.bubble", title: "Текста нет")
                    } else {
                        text(lines)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task {
            lines = (try? await API.shared.lyrics(track: track.id)) ?? []
        }
    }

    private func text(_ lines: [LyricLine]) -> some View {
        let current = active
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(current == nil || line.id == current ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let time = line.time { Player.shared.seek(to: time) }
                            }
                            .id(line.id)
                    }
                }
                .padding(24)
            }
            .onChange(of: current) { line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
        }
    }
}
