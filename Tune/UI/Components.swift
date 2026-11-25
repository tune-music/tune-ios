import Combine
import SwiftUI

private final class RefreshBox: NSObject {
    var action: (@MainActor () async -> Void)?
    var offline = false
    var task: Task<Void, Never>?
    weak var scrollView: UIScrollView?
    weak var overlay: RefreshOverlayView?

    private var offsetObserver: NSKeyValueObservation?
    private weak var observedPan: UIPanGestureRecognizer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var armedForDrag = false
    private var triggeredInDrag = false
    private var isRefreshing = false

    private let revealDistance: CGFloat = 14
    private let triggerDistance: CGFloat = 64

    func attach(_ scroll: UIScrollView) {
        if !scroll.alwaysBounceVertical {
            scroll.alwaysBounceVertical = true
        }
        guard scrollView !== scroll else { return }
        detach()
        scrollView = scroll
        offsetObserver = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.handleScroll()
        }
        let pan = scroll.panGestureRecognizer
        pan.addTarget(self, action: #selector(panChanged(_:)))
        observedPan = pan
    }

    func detach() {
        offsetObserver?.invalidate()
        offsetObserver = nil
        observedPan?.removeTarget(self, action: #selector(panChanged(_:)))
        observedPan = nil
        scrollView = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRefreshing = false
        armedForDrag = false
        triggeredInDrag = false
        updateVisual(animated: false)
    }

    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            triggeredInDrag = false
            if let scroll = scrollView {
                // Засчитываем pull-to-refresh только если жест начался от самого верха,
                // а не при докручивании списка снизу вверх или ловле инерционного отскока.
                let offsetFromTop = scroll.contentOffset.y + scroll.adjustedContentInset.top
                armedForDrag = !scroll.isDecelerating && offsetFromTop <= 20 && offsetFromTop >= -35
            } else {
                armedForDrag = false
            }
            if armedForDrag { haptic.prepare() }
        case .ended, .cancelled, .failed:
            armedForDrag = false
            triggeredInDrag = false
            updateVisual(animated: true)
        default:
            break
        }
    }

    private func handleScroll() {
        guard let scroll = scrollView else { return }
        let pull = currentPull(scroll)
        let panState = scroll.panGestureRecognizer.state
        let activeDrag = armedForDrag && scroll.isDragging && (panState == .began || panState == .changed)
        if activeDrag && !triggeredInDrag && !offline && task == nil && pull >= triggerDistance {
            triggeredInDrag = true
            haptic.impactOccurred()
            startRefresh()
        }
        updateVisual(pull: pull, activeDrag: activeDrag, animated: false)
    }

    private func currentPull(_ scroll: UIScrollView) -> CGFloat {
        max(0, -(scroll.contentOffset.y + scroll.adjustedContentInset.top))
    }

    private func startRefresh() {
        guard task == nil, let action else { return }
        let started = Date()
        isRefreshing = true
        updateVisual(animated: true)
        task = Task { @MainActor [weak self] in
            await action()
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.25 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((0.25 - elapsed) * 1_000_000_000))
            }
            guard let self else { return }
            self.task = nil
            self.isRefreshing = false
            self.updateVisual(animated: true)
        }
    }

    func updateVisual(animated: Bool) {
        guard let scroll = scrollView else {
            overlay?.hide(animated: animated)
            return
        }
        let panState = scroll.panGestureRecognizer.state
        let activeDrag = armedForDrag && scroll.isDragging && (panState == .began || panState == .changed)
        updateVisual(pull: currentPull(scroll), activeDrag: activeDrag, animated: animated)
    }

    private func updateVisual(pull: CGFloat, activeDrag: Bool, animated: Bool) {
        guard let overlay else { return }
        if isRefreshing {
            let y: CGFloat = pull > 18 ? min(pull * 0.5, 70) : 22
            overlay.showSpinning(at: y, showPill: pull < 18, animated: animated)
        } else if !triggeredInDrag && activeDrag && pull > revealDistance && !offline {
            let progress = min(max((pull - revealDistance) / (triggerDistance - revealDistance), 0), 1)
            overlay.showProgress(progress, at: max(20, pull * 0.5))
        } else {
            overlay.hide(animated: animated)
        }
    }

    deinit {
        offsetObserver?.invalidate()
        observedPan?.removeTarget(self, action: nil)
    }
}

private final class RefreshOverlayView: UIView {
    weak var box: RefreshBox?
    private let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let ticksHost = UIView()
    private var spokes: [CALayer] = []
    private var pillVisible = false
    private var spinning = false
    private var lastAngle: CGFloat = 0
    private var lastBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        pill.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        pill.layer.cornerRadius = 17
        pill.clipsToBounds = true
        pill.alpha = 0
        addSubview(pill)

        ticksHost.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        ticksHost.alpha = 0
        ticksHost.isHidden = true
        addSubview(ticksHost)

        for index in 0..<8 {
            let spoke = CALayer()
            spoke.bounds = CGRect(x: 0, y: 0, width: 2, height: 5.5)
            spoke.cornerRadius = 1
            spoke.backgroundColor = UIColor.secondaryLabel.cgColor
            let angle = CGFloat(index) * (.pi / 4)
            let radius: CGFloat = 7
            spoke.position = CGPoint(x: 11 + sin(angle) * radius, y: 11 - cos(angle) * radius)
            spoke.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            ticksHost.layer.addSublayer(spoke)
            spokes.append(spoke)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        box?.updateVisual(animated: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            let color = UIColor.secondaryLabel.cgColor
            for spoke in spokes { spoke.backgroundColor = color }
        }
    }

    func showProgress(_ progress: CGFloat, at y: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: y)
        stopSpin()
        lastAngle = progress * 0.35
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ticksHost.isHidden = false
        ticksHost.center = center
        ticksHost.alpha = progress
        let scale = 0.8 + 0.2 * progress
        ticksHost.transform = CGAffineTransform(scaleX: scale, y: scale).rotated(by: lastAngle)
        for (index, spoke) in spokes.enumerated() {
            let level = min(max(progress * 8 - CGFloat(index), 0.15), 1)
            spoke.opacity = Float(level)
        }
        CATransaction.commit()
        setPillVisible(false, center: center, animated: false)
    }

    func showSpinning(at y: CGFloat, showPill: Bool, animated: Bool) {
        let center = CGPoint(x: bounds.midX, y: y)
        ticksHost.isHidden = false
        ticksHost.center = center
        setPillVisible(showPill, center: center, animated: animated)
        if !spinning {
            spinning = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ticksHost.transform = CGAffineTransform(rotationAngle: lastAngle)
            for (index, spoke) in spokes.enumerated() {
                spoke.opacity = Float(0.22 + 0.78 * CGFloat(index) / 7)
            }
            CATransaction.commit()
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = lastAngle
            spin.toValue = lastAngle + (.pi * 2)
            spin.duration = 0.75
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ticksHost.layer.add(spin, forKey: "spin")
        }
        if animated && ticksHost.alpha < 1 {
            UIView.animate(withDuration: 0.16) { self.ticksHost.alpha = 1 }
        } else {
            ticksHost.alpha = 1
        }
    }

    func hide(animated: Bool) {
        setPillVisible(false, center: ticksHost.center, animated: animated)
        if animated && !ticksHost.isHidden && ticksHost.alpha > 0 {
            UIView.animate(withDuration: 0.18, animations: {
                self.ticksHost.alpha = 0
            }, completion: { _ in
                if self.ticksHost.alpha == 0 {
                    self.ticksHost.isHidden = true
                    self.stopSpin()
                }
            })
        } else {
            ticksHost.alpha = 0
            ticksHost.isHidden = true
            stopSpin()
        }
    }

    private func stopSpin() {
        guard spinning else { return }
        spinning = false
        ticksHost.layer.removeAnimation(forKey: "spin")
    }

    private func setPillVisible(_ visible: Bool, center: CGPoint, animated: Bool) {
        pill.center = center
        guard visible != pillVisible else { return }
        pillVisible = visible
        let target: CGFloat = visible ? 1 : 0
        if animated {
            UIView.animate(withDuration: 0.18) { self.pill.alpha = target }
        } else {
            pill.alpha = target
        }
    }
}

private struct RefreshOverlay: UIViewRepresentable {
    let box: RefreshBox
    let action: @MainActor () async -> Void

    func makeUIView(context: Context) -> RefreshOverlayView {
        let view = RefreshOverlayView()
        view.box = box
        box.overlay = view
        box.action = action
        return view
    }

    func updateUIView(_ uiView: RefreshOverlayView, context: Context) {
        uiView.box = box
        box.overlay = uiView
        box.action = action
    }
}

private struct ScrollDragProbe: UIViewRepresentable {
    let box: RefreshBox

    final class ProbeView: UIView {
        weak var box: RefreshBox?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                box?.detach()
            } else {
                attach()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        func attach() {
            guard let box, window != nil else { return }
            if let existing = box.scrollView, existing.window != nil {
                box.attach(existing)
                return
            }
            if let found = findScrollView() {
                box.attach(found)
            }
        }

        private func findScrollView() -> UIScrollView? {
            var current: UIView? = superview
            var host: UIView? = superview
            var hops = 0
            while let view = current {
                if let scroll = view as? UIScrollView { return scroll }
                host = view
                if view.next is UIViewController || hops >= 4 { break }
                current = view.superview
                hops += 1
            }
            guard let root = host else { return nil }
            var queue: [(UIView, Int)] = [(root, 0)]
            var index = 0
            var fallback: UIScrollView?
            while index < queue.count {
                let (view, depth) = queue[index]
                index += 1
                if let scroll = view as? UIScrollView {
                    if !scroll.alwaysBounceHorizontal && (root.bounds.height == 0 || scroll.bounds.height >= root.bounds.height * 0.5) {
                        return scroll
                    }
                    if fallback == nil, scroll.alwaysBounceVertical || !scroll.alwaysBounceHorizontal {
                        fallback = scroll
                    }
                }
                if depth < 12 {
                    for child in view.subviews { queue.append((child, depth + 1)) }
                }
            }
            return fallback
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.box = box
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.box = box
        uiView.attach()
    }
}

private struct ScreenRefresh: ViewModifier {
    let action: @MainActor () async -> Void
    @State private var box = RefreshBox()

    func body(content: Content) -> some View {
        content
            .background(ScrollDragProbe(box: box))
            .overlay(alignment: .top) {
                RefreshOverlay(box: box, action: action)
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
            .onAppear {
                box.action = action
                box.offline = Connectivity.shared.offline
            }
            .onReceive(Connectivity.shared.$online) { online in
                box.offline = !online
                if !online { box.cancel() }
            }
            .onDisappear { box.cancel() }
    }
}

extension View {
    func screenRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ScreenRefresh(action: action))
    }
}
enum Theme {
    private static func pair(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? light : dark })
    }

    private static func gray(_ dark: CGFloat, _ light: CGFloat) -> Color {
        pair(UIColor(white: dark, alpha: 1), UIColor(white: light, alpha: 1))
    }

    static let background = gray(0, 1)
    /// Жёлтый для заливок: кнопка «Слушать», активная вкладка. Текст на нём всегда чёрный.
    static let accent = Color("AccentColor")
    /// Жёлтый для текста и значков: на белом фоне он темнее, иначе не читается.
    static let accentText = pair(UIColor(red: 0.98, green: 0.8, blue: 0.082, alpha: 1), UIColor(red: 0.72, green: 0.5, blue: 0, alpha: 1))
    static let text = gray(1, 0.07)
    static let surface = gray(0.11, 0.95)
    static let raised = gray(0.17, 0.9)
    static let dim = gray(0.6, 0.42)
    static let tone = gray(0.16, 0.9)

    /// Цвет обложки для фона страницы: в тёмной теме как есть, в светлой — разбавлен белым,
    /// чтобы на нём читался тёмный текст.
    static func wash(_ tone: Color) -> Color {
        Color(UIColor { traits in
            let color = UIColor(tone).resolvedColor(with: traits)
            guard traits.userInterfaceStyle == .light else { return color }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
            let part: CGFloat = 0.3
            return UIColor(red: red * part + 1 - part, green: green * part + 1 - part, blue: blue * part + 1 - part, alpha: 1)
        })
    }
}

/// Тема приложения: системная, тёмная или светлая.
enum Appearance {
    static var style: UIUserInterfaceStyle {
        // Снимки светлой темы в демо-режиме.
        if ProcessInfo.processInfo.arguments.contains("-light") { return .light }
        switch Settings.appearance {
        case 0: return .unspecified
        case 2: return .light
        default: return .dark
        }
    }

    /// Ставит тему всем окнам. Окно плеера всегда тёмное: оно окрашено под обложку.
    @MainActor
    static func apply() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
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

    @ViewBuilder
    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        if let tint {
            self.background(tint, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension Font {
    /// Шрифт текста: следует за системной настройкой размера, но не больше чем на треть —
    /// на это рассчитаны строки и кнопки.
    static func scaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let factor = UIFontMetrics.default.scaledValue(for: 100) / 100
        return .system(size: size * min(max(factor, 0.9), 1.3), weight: weight, design: design)
    }
}

/// Нажатие с откликом: кнопка поджимается под пальцем и пружинит обратно.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.86
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Значок «играть / пауза»: одна фигура перетекает в другую, а не сменяется затуханием.
struct PlayGlyph: View {
    let playing: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let image = Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size))
        if #available(iOS 17.0, *), !reduceMotion {
            image
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: playing)
        } else {
            image
        }
    }
}

@MainActor
final class NavTitleState: ObservableObject {
    @Published var progress: CGFloat = 0

    func setProgress(_ value: CGFloat) {
        if abs(progress - value) > 0.001 {
            progress = value
        }
    }
}

/// Заголовок в панели навигации: плавно проявляется и поднимается, когда шапка уходит вверх.
struct NavBarTitle: View {
    @ObservedObject var state: NavTitleState
    let alwaysShown: Bool
    let hidden: Bool
    let title: String

    var body: some View {
        let progress: CGFloat = hidden ? 0 : (alwaysShown ? 1 : state.progress)
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .foregroundStyle(Theme.text)
            .opacity(progress)
            .offset(y: (1 - progress) * 5)
            .scaleEffect(0.96 + 0.04 * progress)
            .animation(.easeOut(duration: 0.14), value: progress)
            .allowsHitTesting(false)
    }
}

/// Следит, насколько заголовок страницы ушёл под панель навигации (`0...1`).
struct HeaderWatch: View {
    let onProgress: (CGFloat) -> Void
    @State private var lastMaxY: CGFloat = 400

    private var barBottom: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return (window?.safeAreaInsets.top ?? 54) + 44
    }

    var body: some View {
        GeometryReader { geometry in
            let maxY = geometry.frame(in: .global).maxY
            let top = barBottom
            let raw = min(max((top + 38 - maxY) / 40, 0), 1)
            let snapped = (raw * 40).rounded() / 40
            Color.clear
                .onAppear {
                    lastMaxY = maxY
                    onProgress(snapped)
                }
                .onChange(of: snapped) { value in
                    lastMaxY = maxY
                    onProgress(value)
                }
                .onDisappear {
                    if lastMaxY < top + 60 { onProgress(1) }
                }
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
    private var downloads: Downloads { Downloads.shared }
    private var session: Session { Session.shared }

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
        if inPlayer, Uncensor.shared.has(track.id) || player.audibleVersion == .uncensored {
            let versions: [TrackFiles.Version] = track.yandexAvailable == false ? [.uncensored] : TrackFiles.Version.allCases
            ForEach(versions, id: \.rawValue) { version in
                Button {
                    player.selectVersion(version, for: track)
                    done()
                } label: {
                    Label(version.title, systemImage: player.audibleVersion == version ? "checkmark" : "waveform")
                }
                .disabled(player.audibleVersion == version || (!Uncensor.shared.has(track.id) && version == .uncensored))
            }
        }
        Button {
            done()
            pick(track)
        } label: {
            Label("Добавить в плейлист", systemImage: "text.badge.plus")
        }
        if track.isPrivate {
            Button {
                done()
                navigate(.uploadedTrackEditor(track))
            } label: {
                Label("Редактировать трек", systemImage: "pencil")
            }
        }
        Button {
            done()
            navigate(.replacement(ReplacementTarget(kind: .track, id: track.id, title: track.title)))
        } label: {
            Label("Подменить трек", systemImage: "pencil")
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
        if let artist = track.artistList.first(where: { !$0.id.isEmpty }) {
            let blocked = session.isBlocked(artist.id)
            Button {
                session.toggleBlocked(artist)
                done()
            } label: {
                Label(blocked ? "Снова рекомендовать исполнителя" : "Не рекомендовать исполнителя", systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
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

struct UploadedTrackEditor: View {
    let track: Track
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var saving = false
    @State private var failure: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artists)
    }

    var body: some View {
        Form {
            TextField("Название", text: $title)
            TextField("Исполнитель", text: $artist)
        }
        .disabled(saving)
        .navigationTitle("Редактировать трек")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Сохранить", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("Не удалось сохранить трек", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func save() {
        guard !saving else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let performer = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.editUploadedTrack(track, title: name, artist: performer)
                dismiss()
            } catch {
                failure = error.localizedDescription
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
    var historySource: String? = nil
    var badge: String? = nil
    let action: () -> Void

    @State private var playback: RowPlayback
    @State private var downloadProgress: Double?
    @State private var downloaded: Bool
    @State private var liked: Bool
    @State private var disliked: Bool
    private var player: Player { Player.shared }
    private var downloads: Downloads { Downloads.shared }
    @Environment(\.navigate) private var navigate
    @Environment(\.pickPlaylist) private var pickPlaylist

    init(
        track: Track,
        number: Int? = nil,
        fadesDisliked: Bool = true,
        onRemove: (() -> Void)? = nil,
        historySource: String? = nil,
        badge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.track = track
        self.number = number
        self.fadesDisliked = fadesDisliked
        self.onRemove = onRemove
        self.historySource = historySource
        self.badge = badge
        self.action = action
        let now = Player.shared.now
        let initialPlayback: RowPlayback = now.id == track.id ? (now.playing ? .playing : .paused) : .other
        _playback = State(initialValue: initialPlayback)
        _downloadProgress = State(initialValue: Downloads.shared.active[track.id])
        _downloaded = State(initialValue: Downloads.shared.downloadedIds.contains(track.id))
        _liked = State(initialValue: Session.shared.isLiked(track.id))
        _disliked = State(initialValue: Session.shared.disliked.contains(track.id))
    }

    private var dimmed: Bool {
        (track.unavailable && !track.uncensored && !downloaded) || (fadesDisliked && disliked)
    }

    var body: some View {
        let playing = playback != .other
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 12) {
                    lead(playing)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(track.fullTitle)
                                .font(.scaled(size: 16, weight: .medium))
                                .foregroundStyle(playing ? Theme.accentText : Theme.text)
                                .lineLimit(1)
                            TrackMarks(track: track)
                        }
                        HStack(spacing: 5) {
                            if downloaded {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accentText)
                            }
                            Text(track.artists.isEmpty ? track.albumTitle : track.artists)
                                .font(.scaled(size: 14))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                        }
                        if let historySource {
                            Text(historySource)
                                .font(.scaled(size: 12))
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

            if let value = downloadProgress {
                ProgressRing(value: value)
                    .frame(width: 20, height: 20)
                    .padding(.horizontal, 6)
            } else if liked {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 4)
            }
            if number != nil {
                Text(timeText(track.duration))
                    .font(.scaled(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, 4)
            }
            if let badge {
                Text(badge)
                    .font(.scaled(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, 4)
            }
            Menu {
                TrackMenu(track: track, onRemove: onRemove, navigate: navigate, pick: pickPlaylist)
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Ещё")
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
            if downloaded {
                Button(role: .destructive) {
                    downloads.remove(track.id)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .tint(Color(uiColor: .systemRed))
            } else {
                Button {
                    downloads.download(track)
                } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                }
                .tint(Theme.accentText)
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
        .onChange(of: track.id) { _ in
            syncRowState()
        }
        .onReceive(player.now.$id) { id in
            let next: RowPlayback = id == track.id ? (player.now.playing ? .playing : .paused) : .other
            if playback != next { playback = next }
        }
        .onReceive(player.now.$playing) { playing in
            guard player.now.id == track.id else { return }
            let next: RowPlayback = playing ? .playing : .paused
            if playback != next { playback = next }
        }
        .onReceive(downloads.$active) { active in
            let value = active[track.id]
            if downloadProgress != value { downloadProgress = value }
        }
        .onReceive(downloads.$downloadedIds) { ids in
            let value = ids.contains(track.id)
            if downloaded != value { downloaded = value }
        }
        .onReceive(Session.shared.$likedIds) { _ in
            let value = Session.shared.isLiked(track.id)
            if liked != value { liked = value }
        }
        .onReceive(Session.shared.$disliked) { ids in
            let value = ids.contains(track.id)
            if disliked != value { disliked = value }
        }
    }

    private func syncRowState() {
        let now = player.now
        let nextPlayback: RowPlayback = now.id == track.id ? (now.playing ? .playing : .paused) : .other
        if playback != nextPlayback { playback = nextPlayback }
        let nextProgress = downloads.active[track.id]
        if downloadProgress != nextProgress { downloadProgress = nextProgress }
        let nextDownloaded = downloads.downloadedIds.contains(track.id)
        if downloaded != nextDownloaded { downloaded = nextDownloaded }
        let nextLiked = Session.shared.isLiked(track.id)
        if liked != nextLiked { liked = nextLiked }
        let nextDisliked = Session.shared.disliked.contains(track.id)
        if disliked != nextDisliked { disliked = nextDisliked }
    }

    private enum RowPlayback {
        case other, paused, playing
    }
}

extension TrackRow {
    /// Слева обложка, а в альбоме — номер трека. У играющего трека вместо них значок.
    @ViewBuilder
    fileprivate func lead(_ playing: Bool) -> some View {
        let mark = PlayingBars(playing: playback == .playing, size: 18)
        if let number {
            ZStack {
                if playing {
                    mark
                } else {
                    Text("\(number)")
                        .font(.scaled(size: 16, weight: .medium).monospacedDigit())
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
                .font(.scaled(size: 15, weight: .medium))
                .foregroundStyle(playing == nil ? Theme.text : Theme.accentText)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.scaled(size: 13))
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

    private var mark: some View {
        PlayingBars(playing: playing, size: size * 0.46, color: .black)
    }
}

/// Значки у названия трека, как в Tune Native: «E» — ненормативная лексика, открытый замок —
/// играет версия без цензуры, перечёркнутый глаз — свой загруженный трек, его слышите только вы.
struct TrackMarks: View {
    let track: Track
    var size: CGFloat = 14
    /// Тёмный фон (полноэкранный плеер): значки светлые в любой теме.
    var onDark = false

    var body: some View {
        if track.explicit || track.uncensored || track.isPrivate {
            HStack(spacing: 4) {
                if track.explicit {
                    badge(Text("E").font(.system(size: size * 0.68, weight: .heavy)))
                }
                if track.uncensored {
                    badge(Image(systemName: "lock.open.fill").font(.system(size: size * 0.6, weight: .bold)))
                        .accessibilityLabel("Без цензуры")
                }
                if track.isPrivate {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(onDark ? Color.white.opacity(0.6) : Theme.dim)
                        .accessibilityLabel("Этот трек можете слушать только вы")
                }
            }
            .fixedSize()
        }
    }

    private func badge<Content: View>(_ content: Content) -> some View {
        content
            .foregroundStyle(onDark ? Color.black : Theme.background)
            .frame(width: size, height: size)
            .background(onDark ? Color.white.opacity(0.75) : Theme.dim, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Живые полоски играющего трека: прыгают, пока звук идёт, и замирают на паузе.
struct PlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    let playing: Bool
    var size: CGFloat = 16
    var color: Color = Theme.accentText

    private static let speeds: [Double] = [2.4, 3.3, 2.8, 3.8]
    private static let phases: [Double] = [0, 1.3, 2.2, 0.6]
    private static let rest: [Double] = [0.45, 0.85, 0.6, 0.35]

    var body: some View {
        let still = !playing || phase != .active || reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: size * 0.12) {
                ForEach(0..<4, id: \.self) { bar in
                    let level = still ? Self.rest[bar] : 0.3 + 0.7 * abs(sin(time * Self.speeds[bar] + Self.phases[bar]))
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.16, height: max(size * 0.18, size * level))
                }
            }
            .frame(width: size, height: size, alignment: .bottom)
        }
        .accessibilityLabel(playing ? "Играет" : "Пауза")
    }
}

/// Кружок волны для плашек: цвет волны и её картинка от Яндекса.
struct WaveDot: View {
    let wave: WaveCard
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: wave.color) ?? Theme.raised)
            if let cover = wave.cover {
                CoverView(uri: cover, size: size, round: true, backdrop: nil)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
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
                CardView(title: card.title, subtitle: card.subtitle == "Исполнитель" ? "" : card.subtitle, cover: card.cover, round: true, size: size, playing: playing("artist", card.id))
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

extension HomeItem {
    var coverURI: String? {
        switch self {
        case .album(let card), .artist(let card): return card.cover
        case .playlist(let playlist): return playlist.cover
        case .wave(let wave): return wave.cover
        }
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
                    .fill(color)
                if let cover = wave.cover {
                    CoverView(uri: cover, size: size, round: true, backdrop: nil)
                }
                if let playing {
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 3)
                    PlayingBadge(playing: playing, size: 52)
                } else if wave.cover == nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            Text(wave.title)
                .font(.scaled(size: 15, weight: .medium))
                .foregroundStyle(playing == nil ? Theme.text : Theme.accentText)
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
                    .font(.scaled(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
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
                .font(.scaled(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            if !text.isEmpty {
                Text(text)
                    .font(.scaled(size: 15))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Text("Повторить")
                        .font(.scaled(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
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
                .tint(Theme.text)
            Spacer()
        }
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Заглушка списка треков, пока он грузится: очертания строк вместо крутилки.
struct RowsSkeleton: View {
    var count = 7
    @State private var dim = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule()
                            .fill(Theme.surface)
                            .frame(width: index % 2 == 0 ? 170 : 120, height: 12)
                        Capsule()
                            .fill(Theme.surface)
                            .frame(width: index % 3 == 0 ? 90 : 130, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 60)
            }
        }
        .padding(.horizontal, 16)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityHidden(true)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}

/// Заглушка сетки в два столбца: карточки альбомов или плитки волн.
struct TilesSkeleton: View {
    var height: CGFloat = 190
    var count = 6
    @State private var dim = false

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: height)
            }
        }
        .padding(.horizontal, 16)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityHidden(true)
    }
}

/// Плитка вместо обложки у «Мне нравится», «Скачанного» и «Истории».
struct SymbolCover: View {
    let symbol: String
    let colors: [Color]
    let size: CGFloat
    var corner: CGFloat = 12

    /// «Мне нравится» — единственная цветная обложка: это главный раздел коллекции.
    static let likes = [Color(red: 1, green: 0.83, blue: 0.25), Color(red: 0.97, green: 0.66, blue: 0.1)]
    static let plain = [
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(white: 0.84, alpha: 1) : UIColor(white: 0.25, alpha: 1) }),
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.15, alpha: 1) }),
    ]
    static let downloads = plain
    static let history = plain
    static let disliked = plain

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(colors == Self.likes ? Color.black : Theme.text)
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
                .foregroundStyle(active ? Theme.accentText : Theme.text)
                .frame(width: 50, height: 50)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// Главная кнопка страницы: жёлтая «Слушать».
struct PlayButton: View {
    var title = "Слушать"
    /// Откуда играет список: если сейчас звучит он, кнопка ставит на паузу и продолжает.
    var context: PlayContext?
    let action: () -> Void

    @ObservedObject private var now = Player.shared.now

    private var active: Bool {
        guard let context else { return false }
        return now.kind == context.kind && now.item == context.item && (context.item != nil || now.name == context.name)
    }

    var body: some View {
        let on = active
        Button {
            if on { Player.shared.toggle() } else { action() }
        } label: {
            HStack(spacing: 8) {
                if on, now.playing {
                    PlayingBars(playing: true, size: 17, color: .black)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    PlayGlyph(playing: false, size: 17)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(on ? (now.playing ? "Пауза" : "Продолжить") : title)
                    .contentTransition(.identity)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.accent, in: Capsule())
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: on)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: now.playing)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// Горизонтальная полоса фильтров по настроениям и жанрам над списком треков.
struct TrackFilterBar: View {
    let filters: [TrackFilter]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(id: nil, title: "Всё", on: selected == nil)
                ForEach(filters) { item in
                    chip(id: item.id, title: item.name, on: selected == item.id)
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
    }

    private func chip(id: String?, title: String, on: Bool) -> some View {
        Button {
            if let id {
                selected = (selected == id) ? nil : id
            } else {
                selected = nil
            }
        } label: {
            Text(title)
                .font(.scaled(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.black : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(on ? Theme.accent : Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Короткое сообщение. На страницах оно всплывает снизу, над мини-плеером: наверху
/// оно закрывало кнопки навигации. В плеере — под его шапкой.
struct ToastView: View {
    var bottom = false

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player

    var body: some View {
        // Снимок для проверки места: в демо-режиме сообщение не пропадает.
        let text = session.toast ?? (Demo.screen == "toast" ? "Добавлено в плейлист «В дорогу»" : nil)
        ZStack {
            if let text {
                Text(text)
                    .font(.scaled(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glass(in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.top, bottom ? 0 : 58)
                    .padding(.bottom, bottom ? (player.current == nil ? 64 : 132) : 0)
                    .transition(.move(edge: bottom ? .bottom : .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.toast)
        .allowsHitTesting(false)
    }
}

/// Место под мини-плеер внизу страницы.
struct MiniPlayerSpace: View {
    @State private var hasTrack = Player.shared.now.id != nil

    var body: some View {
        Color.clear.frame(height: hasTrack ? 68 : 0)
            .onReceive(Player.shared.now.$id.map { $0 != nil }.removeDuplicates()) { visible in
                hasTrack = visible
            }
    }
}

@available(iOS 26.1, *)
struct TabMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayer(attached: true, compact: placement == .inline)
    }
}

/// Плашка с текущим треком над панелью вкладок. Смахивание вверх открывает плеер,
/// в стороны — переключает трек.
struct MiniPlayer: View {
    /// Страница под плашкой светлая: стеклу нужна тёмная подложка, иначе белый текст не читается.
    var light = false
    var attached = false
    var compact = false

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @Environment(\.openPlayer) private var openPlayer
    @Environment(\.colorScheme) private var scheme
    @State private var tone = Theme.tone
    /// Сдвиг названия под пальцем.
    @StateObject private var drag = TrackDrag()

    var body: some View {
        if let track = player.current {
            let liked = session.isLiked(track.id)
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            HStack(spacing: 0) {
                TrackPager(style: .row, track: track, drag: drag, onOpen: openPlayer,
                           lightBackground: attached && scheme == .light)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([track.fullTitle, track.artists].filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityHint("Открывает плеер")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openPlayer() }
                    .accessibilityAction(named: Text("Следующий трек")) { player.next() }
                    .accessibilityAction(named: Text("Предыдущий трек")) { player.previous() }
                    .accessibilityAction(named: Text(liked ? "Снять лайк" : "Поставить лайк")) { session.toggleLike(track) }

                if !compact {
                    Button {
                        session.toggleLike(track)
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundStyle(liked ? Theme.accentText : Theme.text)
                            .frame(width: 46)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(liked ? "Снять лайк" : "Поставить лайк")
                    .accessibilityAddTraits(liked ? .isSelected : [])
                }
                Button {
                    player.toggle()
                } label: {
                    PlayGlyph(playing: player.isPlaying, size: 22)
                        .foregroundStyle(Theme.text)
                        .opacity(player.isBuffering ? 0.5 : 1)
                        .frame(width: compact ? 44 : 50)
                    .frame(maxHeight: .infinity)
                    // Нажатие ловит вся площадь кнопки, а не только сам значок.
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Продолжить")
            }
            .padding(.leading, attached ? 10 : 8)
            .padding(.trailing, 2)
            .frame(height: attached ? (compact ? 44 : 52) : 58)
            .overlay(alignment: .bottom) {
                if !compact {
                    MiniProgress(progress: player.progress)
                        .padding(.horizontal, 18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Стекло лежит подложкой под кнопками и не перехватывает их нажатия.
            .background {
                if !attached {
                    if light {
                        shape.fill(Color(white: 0.1).opacity(0.8))
                    }
                    Color.clear.glass(in: shape, tint: tone.opacity(0.75))
                        .animation(.easeInOut(duration: 0.3), value: tone)
                }
            }
            .contentShape(shape)
            .padding(.horizontal, attached ? 0 : 10)
            .padding(.bottom, attached ? 0 : 6)
            .task(id: track.cover) {
                guard !attached else { return }
                let color = await ImageLoader.shared.tone(track.cover)
                guard !Task.isCancelled else { return }
                tone = color ?? Theme.tone
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
                .fill(Theme.text)
                .frame(width: geometry.size.width * share)
        }
        .frame(height: 2)
        .background(Theme.text.opacity(0.18), in: Capsule())
    }
}
