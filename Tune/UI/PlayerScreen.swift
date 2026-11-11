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
    @EnvironmentObject private var router: Router
    /// Плеер лежит поверх вкладок, а не в отдельном окне: при смахивании под ним видно приложение.
    let close: () -> Void
    @State private var panel: Panel? = Demo.screen == "queue" ? .queue : Demo.screen == "lyrics" ? .lyrics : nil
    @State private var picking: Track?
    @State private var tone = Theme.tone
    @State private var drag: CGFloat = 0
    /// Сдвиг обложки, когда её смахивают в сторону, чтобы переключить трек.
    @State private var slide: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let side = max(140, min(geometry.size.width - 48, geometry.size.height * 0.44))
            VStack(spacing: 0) {
                top
                Spacer(minLength: 10)
                CoverView(uri: player.current?.cover, size: side, corner: 22)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
                    .scaleEffect(player.isPlaying ? 1 : 0.9)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                    .offset(x: slide * 0.7)
                    .opacity(1 - min(abs(slide) / 320, 0.5))
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
            ZStack {
                Color(white: 0.05)
                LinearGradient(colors: [tone, Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            }
            // Скругление появляется, когда плеер тянут вниз: видно, что это отдельный лист.
            .clipShape(RoundedRectangle(cornerRadius: drag > 0 ? 38 : 0, style: .continuous))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            ToastView()
        }
        .offset(y: drag)
        .gesture(
            // Смахивание вниз закрывает плеер, в стороны — переключает трек.
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    let move = value.translation
                    if drag == 0, slide != 0 || abs(move.width) > abs(move.height) {
                        slide = move.width
                    } else if move.height > 0 {
                        drag = move.height
                    }
                }
                .onEnded { value in
                    if slide != 0 {
                        if slide < -70 { player.next() } else if slide > 70 { player.previous() }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { slide = 0 }
                    } else if value.translation.height > 140 {
                        close()
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
        .sheet(item: $picking) { track in
            PlaylistPicker(track: track)
        }
        .onChange(of: player.current == nil) { empty in
            if empty { close() }
        }
    }

    private var top: some View {
        HStack {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
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
            Menu {
                if let track = player.current {
                    TrackMenu(
                        track: track, inPlayer: true,
                        navigate: { route in
                            close()
                            router.push(route)
                        },
                        pick: { picking = $0 })
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            // Стекло на самом меню, а не на значке: при удержании подсвечивается круг, а не квадрат.
            .glass(in: Circle(), interactive: true)
            .clipShape(Circle())
        }
        .foregroundStyle(.white)
    }

    private func titles(_ track: Track) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.fullTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if track.uncensored {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(track.artists)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            let disliked = session.disliked.contains(track.id)
            Button(action: player.dislikeCurrent) {
                Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 22))
                    .foregroundStyle(disliked ? Theme.accent : Color.white.opacity(0.8))
                    .frame(width: 44, height: 48)
            }
            .buttonStyle(.plain)
            let liked = session.isLiked(track.id)
            Button {
                session.toggleLike(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 26))
                    .foregroundStyle(liked ? Theme.accent : Color.white)
                    .frame(width: 44, height: 48)
            }
            .buttonStyle(.plain)
        }
    }

    private var controls: some View {
        HStack {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Theme.accent : Color.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .disabled(player.isWave)
            .opacity(player.isWave ? 0.35 : 1)
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
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.6) : Theme.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var sleeping: Bool {
        player.sleepAt != nil || player.sleepAfterTrack
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
            RoutePicker()
                .frame(width: 48, height: 44)
            Spacer()
            Menu {
                if let date = player.sleepAt {
                    Text("Остановится в \(date.formatted(date: .omitted, time: .shortened))")
                } else if player.sleepAfterTrack {
                    Text("Остановится после этого трека")
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("Через \(minutes) минут") { player.setSleep(minutes: minutes) }
                }
                Button("После этого трека") { player.sleepAfterCurrentTrack() }
                if sleeping {
                    Button("Выключить таймер", role: .destructive) { player.setSleep(minutes: nil) }
                }
            } label: {
                Image(systemName: sleeping ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(sleeping ? Theme.accent : Color.white.opacity(0.85))
                    .frame(width: 48, height: 44)
            }
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
                        .foregroundStyle(Theme.accent)
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
        .buttonStyle(.plain)
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
                .frame(height: drag == nil ? 5 : 10)
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
        view.tintColor = UIColor(white: 1, alpha: 0.85)
        view.activeTintColor = UIColor(named: "AccentColor")
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Очередь: нажатие переключает трек, «Изменить» даёт переставлять и убирать треки.
private struct QueueSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var mode = EditMode.inactive

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                        Button {
                            player.jump(to: index)
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(uri: track.cover, size: 46, corner: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.fullTitle)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(index == player.index ? Theme.accent : Color.white)
                                        .lineLimit(1)
                                    Text(track.artists)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if index == player.index {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(index < player.index ? 0.5 : 1)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .deleteDisabled(index == player.index)
                        .id(index)
                    }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                    .onDelete { player.removeFromQueue($0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(white: 0.07))
                .environment(\.editMode, $mode)
                .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            }
            .navigationTitle(player.contextName.isEmpty ? "Очередь" : player.contextName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == .active ? "Готово" : "Изменить") {
                        withAnimation { mode = mode == .active ? .inactive : .active }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
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
                    Button("Закрыть") { dismiss() }
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
