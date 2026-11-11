import AVKit
import SwiftUI

/// Сдвиг обложки под пальцем. Отдельный объект, чтобы жест жил на всём экране плеера,
/// а перерисовывалась от него только обложка.
@MainActor
final class CoverSwipe: ObservableObject {
    @Published var x: CGFloat = 0
    @Published var forward = true
}

/// Полноэкранный плеер. Показывается в собственном окне (PlayerWindow), которое и двигается
/// под пальцем: здесь только жесты, содержимое при перетаскивании не пересчитывается.
struct PlayerScreen: View {
    @StateObject private var swipe = CoverSwipe()
    @State private var axis: Axis?

    var body: some View {
        PlayerBody()
            .environmentObject(swipe)
            .background {
                PlayerBackdrop()
            }
            .overlay(alignment: .top) {
                ToastView()
            }
            .gesture(
                // Вниз — закрыть плеер, в стороны — переключить трек. Направление жеста
                // определяется в его начале и до конца не меняется.
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let move = value.translation
                        if axis == nil { axis = abs(move.width) > abs(move.height) ? .horizontal : .vertical }
                        if axis == .vertical {
                            PlayerWindow.shared.drag(move.height)
                        } else {
                            swipe.x = move.width
                            let ahead = move.width < 0
                            if ahead != swipe.forward { swipe.forward = ahead }
                        }
                    }
                    .onEnded { value in
                        let locked = axis
                        axis = nil
                        if locked == .horizontal {
                            let far = abs(value.translation.width) > 70 || abs(value.predictedEndTranslation.width) > 220
                            if far {
                                if swipe.forward { Player.shared.next() } else { Player.shared.previous() }
                            }
                            withAnimation(.easeOut(duration: 0.26)) { swipe.x = 0 }
                        } else {
                            PlayerWindow.shared.release(predicted: value.predictedEndTranslation.height)
                        }
                    }
            )
    }
}

/// Фон плеера: цвет обложки, уходящий в чёрный.
private struct PlayerBackdrop: View {
    @EnvironmentObject private var player: Player
    @State private var tone = Theme.tone

    var body: some View {
        ZStack {
            Color(white: 0.05)
            LinearGradient(colors: [tone, Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .task(id: player.current?.cover) {
            let color = await ImageLoader.shared.tone(player.current?.cover)
            withAnimation(.easeInOut(duration: 0.4)) { tone = color ?? Theme.tone }
        }
    }
}

/// Обложка: при смене трека новая въезжает с той стороны, куда смахнули.
private struct PlayerCover: View {
    let side: CGFloat
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var swipe: CoverSwipe

    var body: some View {
        ZStack {
            CoverView(uri: player.current?.cover, size: side, corner: 22)
                .offset(x: swipe.x * 0.7)
                .opacity(1 - min(Double(abs(swipe.x)) / 320.0, 0.5))
                .id(player.current?.id)
                .transition(.asymmetric(
                    insertion: .move(edge: swipe.forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: swipe.forward ? .leading : .trailing).combined(with: .opacity)))
        }
        // Анимируется только сама обложка: смена трека не тянет за собой анимацию всего экрана.
        .animation(.easeOut(duration: 0.26), value: player.current?.id)
        .shadow(color: .black.opacity(0.4), radius: 22, y: 14)
        .scaleEffect(player.isPlaying ? 1 : 0.9)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
    }
}

/// Содержимое плеера. Входных данных у него нет: экран перерисовывается только от своих
/// источников (плеер, коллекция, загрузки), а не от сдвига под пальцем.
private struct PlayerBody: View {
    @Environment(\.closePlayer) private var close
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var router: Router
    @State private var queue = Demo.screen == "queue"
    /// Текст песни показывается на месте обложки.
    @State private var lyrics = Demo.screen == "lyrics"
    @State private var picking: Track?
    @State private var actions = Demo.screen == "actions"
    @State private var sleep = false

    var body: some View {
        GeometryReader { geometry in
            let side = max(140, min(geometry.size.width - 48, geometry.size.height * 0.44))
            VStack(spacing: 0) {
                top
                ZStack {
                    if lyrics, let track = player.current {
                        LyricsPane(track: track, progress: player.progress)
                            .transition(.opacity)
                    } else {
                        PlayerCover(side: side)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.25), value: lyrics)
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
        .sheet(isPresented: $queue) {
            QueueSheet()
        }
        .sheet(isPresented: $actions) {
            if let track = player.current {
                TrackActionsSheet(
                    track: track,
                    navigate: { route in
                        close()
                        router.push(route)
                    },
                    // Выбор плейлиста открывается, когда этот лист уже закрылся.
                    pick: { track in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { picking = track }
                    })
            }
        }
        .sheet(isPresented: $sleep) {
            SleepSheet()
        }
        .sheet(item: $picking) { track in
            PlaylistPicker(track: track)
        }
        .onChange(of: player.current == nil) { empty in
            if empty { close() }
        }
        .alert("Tune", isPresented: Binding(get: { player.errorText != nil }, set: { if !$0 { player.errorText = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(player.errorText ?? "")
        }
    }

    /// Что за очередь играет: волна, альбом, плейлист.
    private var sourceLabel: String {
        switch player.now.kind {
        case "radio": return "ИГРАЕТ ВОЛНА"
        case "album": return "ИГРАЕТ АЛЬБОМ"
        case "playlist": return "ИГРАЕТ ПЛЕЙЛИСТ"
        case "artist": return "ИГРАЕТ ИСПОЛНИТЕЛЬ"
        default: return "ИГРАЕТ"
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
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text(sourceLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.6))
                Text(player.contextName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            // Меню открывается листом, а не всплывающим окном: всплывающее система
            // прикрепляет к экрану, и его кнопка отставала от плеера при сворачивании.
            Button {
                actions = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
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
                // Нажатие на исполнителя ведёт на его страницу.
                Button {
                    guard let artist = track.artistList.first(where: { !$0.id.isEmpty }) else { return }
                    close()
                    router.push(.artist(artist.id, artist.name))
                } label: {
                    Text(track.artists)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            let disliked = session.disliked.contains(track.id)
            Button(action: player.dislikeCurrent) {
                Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 22))
                    .foregroundStyle(disliked ? Theme.accent : Color.white.opacity(0.8))
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            let liked = session.isLiked(track.id)
            Button {
                session.toggleLike(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 26))
                    .foregroundStyle(liked ? Theme.accent : Color.white)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
    }

    private var controls: some View {
        HStack {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Theme.accent : Color.white.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player.isWave)
            .opacity(player.isWave ? 0.35 : 1)
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button(action: player.toggle) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                    PlayGlyph(playing: player.isPlaying, size: 30)
                        .foregroundStyle(.black)
                }
                .frame(width: 76, height: 76)
                .overlay {
                    // Пока трек грузится, вокруг кнопки бежит дуга; сам значок не пропадает.
                    if player.isBuffering {
                        BufferRing()
                            .padding(-7)
                    }
                }
            }
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button(action: player.cycleRepeat) {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.6) : Theme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
    }

    private var sleeping: Bool {
        player.sleepAt != nil || player.sleepAfterTrack
    }

    private func bottom(_ track: Track) -> some View {
        HStack {
            Button {
                lyrics.toggle()
            } label: {
                Image(systemName: "text.quote")
                    .foregroundStyle(lyrics ? Theme.accent : Color.white.opacity(0.85))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!track.hasLyrics && !lyrics)
            .opacity(track.hasLyrics || lyrics ? 1 : 0.35)
            Spacer()
            RoutePicker()
                .frame(width: 48, height: 44)
            Spacer()
            Button {
                sleep = true
            } label: {
                Image(systemName: sleeping ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(sleeping ? Theme.accent : Color.white.opacity(0.85))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
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
                        .contentShape(Rectangle())
                }
            } else {
                Button {
                    downloads.download(track)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
            }
            Spacer()
            Button {
                queue = true
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Дуга, бегущая вокруг кнопки, пока трек грузится. Появляется не сразу: при обычном
/// запуске трек готов раньше, и дуга не успевает мелькнуть.
private struct BufferRing: View {
    @State private var turning = false
    @State private var shown = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .opacity(shown ? 1 : 0)
            .onAppear { turning = true }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.2)) { shown = true }
            }
    }
}

/// Действия с играющим треком: лист снизу.
private struct TrackActionsSheet: View {
    let track: Track
    let navigate: (Route) -> Void
    let pick: (Track) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            HStack(spacing: 12) {
                CoverView(uri: track.cover, size: 56, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.fullTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artists)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 10, trailing: 20))
            Group {
                TrackMenu(track: track, inPlayer: true, navigate: navigate, pick: pick, done: { dismiss() })
            }
            .font(.system(size: 17))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .tint(.white)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Таймер сна: лист снизу.
private struct SleepSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    private var active: Bool { player.sleepAt != nil || player.sleepAfterTrack }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 4) {
                Text("Таймер сна")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                if let date = player.sleepAt {
                    Text("Музыка остановится в \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                } else if player.sleepAfterTrack {
                    Text("Музыка остановится после этого трека")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
            Group {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button {
                        player.setSleep(minutes: minutes)
                        dismiss()
                    } label: {
                        Label("Через \(minutes) минут", systemImage: "timer")
                    }
                }
                Button {
                    player.sleepAfterCurrentTrack()
                    dismiss()
                } label: {
                    Label("После этого трека", systemImage: "music.note")
                }
                if active {
                    Button(role: .destructive) {
                        player.setSleep(minutes: nil)
                        dismiss()
                    } label: {
                        Label("Выключить таймер", systemImage: "xmark.circle")
                    }
                }
            }
            .font(.system(size: 17))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .tint(.white)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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

/// Текст песни на месте обложки: звучащая строка подсвечена, нажатие на строку перематывает.
private struct LyricsPane: View {
    let track: Track
    @ObservedObject var progress: PlaybackProgress
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
        Group {
            if let lines {
                if lines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 34))
                        Text("Текста нет")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                } else {
                    text(lines)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: track.id) {
            lines = nil
            lines = (try? await API.shared.lyrics(track: track.id)) ?? []
        }
    }

    private func text(_ lines: [LyricLine]) -> some View {
        let current = active
        let timed = lines.contains { $0.time != nil }
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    ForEach(lines) { line in
                        let on = !timed || line.id == current
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 24, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(on ? 1 : 0.32))
                            .scaleEffect(on ? 1 : 0.9)
                            .frame(maxWidth: .infinity)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: on)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let time = line.time { Player.shared.seek(to: time) }
                            }
                            .id(line.id)
                    }
                }
                // Запас сверху и снизу: первая и последняя строки тоже встают по центру.
                .padding(.vertical, 130)
            }
            // Строки растворяются у верхнего и нижнего края.
            .mask {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: current) { line in
                guard let line else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
        }
    }
}
