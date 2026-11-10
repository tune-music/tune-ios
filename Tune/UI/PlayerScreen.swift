import AVKit
import SwiftUI

/// Полноэкранный плеер: фон подстраивается под цвет обложки.
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
    @State private var tone = Theme.tone
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let side = max(140, min(geometry.size.width - 48, geometry.size.height * 0.44))
            VStack(spacing: 0) {
                top
                Spacer(minLength: 10)
                CoverView(uri: player.current?.cover, size: side, corner: 18)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
                    .scaleEffect(player.isPlaying ? 1 : 0.9)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                Spacer(minLength: 10)
                if let track = player.current {
                    titles(track)
                    SeekBar(progress: player.progress) { player.seek(to: $0) }
                        .padding(.top, 18)
                    controls
                        .padding(.top, 14)
                    bottom(track)
                        .padding(.top, 22)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            LinearGradient(colors: [tone, Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .offset(y: drag)
        .gesture(
            // Смахивание вниз закрывает плеер.
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    if value.translation.height > 0 { drag = value.translation.height }
                }
                .onEnded { value in
                    if value.translation.height > 140 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                    }
                }
        )
        .task(id: player.current?.cover) {
            let color = await ImageLoader.shared.tone(player.current?.cover)
            withAnimation(.easeInOut(duration: 0.4)) { tone = color ?? Theme.tone }
        }
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
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(player.isWave ? "ИГРАЕТ ВОЛНА" : "ИГРАЕТ")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.6))
                Text(player.contextName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            RoutePicker()
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
    }

    private func titles(_ track: Track) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.fullTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if track.uncensored {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(track.artists)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let liked = session.isLiked(track.id)
            Button {
                session.toggleLike(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 26))
                    .foregroundStyle(liked ? Color.accentColor : Color.white)
                    .frame(width: 48, height: 48)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Color.accentColor : Color.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
            }
            Spacer()
            Button(action: player.toggle) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                    if player.isBuffering {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 76, height: 76)
            }
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
            }
            Spacer()
            Button(action: player.cycleRepeat) {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.6) : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
    }

    private func bottom(_ track: Track) -> some View {
        HStack {
            Button {
                panel = .lyrics
            } label: {
                Image(systemName: "text.quote")
                    .frame(width: 48, height: 44)
            }
            .disabled(!track.hasLyrics)
            .opacity(track.hasLyrics ? 1 : 0.35)
            Spacer()
            if let value = downloads.active[track.id] {
                ProgressRing(value: value)
                    .frame(width: 22, height: 22)
                    .frame(width: 48, height: 44)
            } else if downloads.has(track.id) {
                Button {
                    downloads.remove(track.id)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 44)
                }
            } else {
                Button {
                    downloads.download(track)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 48, height: 44)
                }
            }
            Spacer()
            Button {
                panel = .queue
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 48, height: 44)
            }
        }
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Полоса перемотки: тонкая линия, которая утолщается под пальцем.
private struct SeekBar: View {
    @ObservedObject var progress: PlaybackProgress
    let seek: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let length = max(progress.duration, 1)
        let value = min(max(drag ?? progress.position, 0), length)
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, width * value / length))
                }
                .frame(height: drag == nil ? 4 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            drag = min(max(gesture.location.x / max(width, 1), 0), 1) * length
                        }
                        .onEnded { _ in
                            if let target = drag { seek(target) }
                            drag = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: drag == nil)
            }
            .frame(height: 24)
            HStack {
                Text(timeText(value))
                Spacer()
                Text(timeText(progress.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
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
                                CoverView(uri: track.cover, size: 46, corner: 6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.fullTitle)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(index == player.index ? Color.accentColor : Color.white)
                                        .lineLimit(1)
                                    Text(track.artists)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.dim)
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
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(white: 0.07))
                .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(.white)
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
                        Placeholder(icon: "text.quote", title: "Текста нет")
                    } else {
                        text(lines)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.07))
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(.white)
        .task {
            lines = (try? await API.shared.lyrics(track: track.id)) ?? []
        }
    }

    private func text(_ lines: [LyricLine]) -> some View {
        let current = active
        let timed = lines.contains { $0.time != nil }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(!timed || line.id == current ? Color.white : Color.white.opacity(0.35))
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
