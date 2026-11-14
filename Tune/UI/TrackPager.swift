import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Страница ленты: обложка трека (полноэкранный плеер) или обложка с названием (мини-плеер).
final class TrackPage: UIView {
    enum Style {
        case cover
        case row
    }

    private let style: Style
    private let art = UIImageView()
    private let note = UIImageView(image: UIImage(systemName: "music.note"))
    private let title = UILabel()
    private let artist = UILabel()
    private var request = 0
    private(set) var track: Track?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.backgroundColor = UIColor(white: 0.14, alpha: 1)
        art.layer.cornerCurve = .continuous
        note.tintColor = UIColor(white: 0.32, alpha: 1)
        note.contentMode = .scaleAspectFit
        addSubview(art)
        addSubview(note)
        switch style {
        case .cover:
            art.layer.cornerRadius = 22
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 22
            layer.shadowOffset = CGSize(width: 0, height: 14)
        case .row:
            art.layer.cornerRadius = 10
            title.font = .systemFont(ofSize: 15, weight: .semibold)
            title.textColor = .white
            artist.font = .systemFont(ofSize: 13)
            artist.textColor = UIColor(white: 1, alpha: 0.65)
            addSubview(title)
            addSubview(artist)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch style {
        case .cover:
            art.frame = bounds
            let mark = bounds.width * 0.36
            note.frame = CGRect(x: (bounds.width - mark) / 2, y: (bounds.height - mark) / 2, width: mark, height: mark)
            // Готовый контур тени: система не вычисляет её по содержимому на каждом кадре.
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
        case .row:
            let side: CGFloat = 42
            art.frame = CGRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
            note.frame = art.frame.insetBy(dx: 12, dy: 12)
            let left = side + 10
            let width = max(0, bounds.width - left)
            let top = (bounds.height - 36) / 2
            title.frame = CGRect(x: left, y: top, width: width, height: 19)
            artist.frame = CGRect(x: left, y: top + 20, width: width, height: 16)
        }
    }

    /// Название со значками, как в Tune Native: «E», без цензуры, только для вас.
    private static func marked(_ track: Track) -> NSAttributedString {
        let text = NSMutableAttributedString(string: track.fullTitle)
        let size: CGFloat = 12
        func add(_ symbol: String, _ color: UIColor) {
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            guard let image = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(string: "  "))
            text.append(NSAttributedString(attachment: attachment))
        }
        let mark = UIColor(white: 1, alpha: 0.65)
        if track.explicit { add("e.square.fill", mark) }
        if track.uncensored { add("lock.open.fill", mark) }
        if track.isPrivate { add("eye.slash.fill", mark) }
        return text
    }

    func show(_ track: Track?) {
        guard track?.id != self.track?.id || track?.cover != self.track?.cover else { return }
        self.track = track
        title.attributedText = track.map(Self.marked)
        artist.text = track?.artists
        request += 1
        let mine = request
        let uri = track?.cover
        let side = ImageLoader.side(for: style == .cover ? max(bounds.width, 300) : 42)
        if let ready = ImageLoader.shared.cached(uri, side: side) {
            art.image = ready
            note.isHidden = true
            return
        }
        art.image = nil
        note.isHidden = false
        Task { @MainActor [weak self] in
            let image = await ImageLoader.shared.load(uri, side: side)
            guard let self, self.request == mine, let image else { return }
            self.art.image = image
            self.note.isHidden = true
        }
    }
}

/// Лента из двух страниц: играющий трек и его сосед. Двигает её Core Animation, а не SwiftUI:
/// анимация идёт в системном потоке отрисовки и не теряет кадры, пока приложение занято
/// загрузкой нового трека и перерисовкой списков.
final class TrackPagerView: UIView {
    private let style: TrackPage.Style
    private var front: TrackPage
    private var back: TrackPage
    /// С какой стороны стоит соседняя страница: true — справа.
    private var ahead = true
    private var run = 0

    var trackId: String? { front.track?.id }

    /// Нажатие и смахивание вверх: открыть плеер. Задаётся у ленты, которая сама ловит касания.
    private var onOpen: (() -> Void)?
    /// Направление жеста: true — в сторону, false — вверх или вниз, nil — ещё не ясно.
    private var sideways: Bool?
    private let own = TrackDrag()

    /// Лента сама ловит касания. Палец она забирает в момент касания, не дожидаясь, пока
    /// системные жесты (например, «назад» по всей странице) решат, не их ли это движение:
    /// поэтому она трогается с места сразу, без «примагничивания».
    func enableTouch(_ open: @escaping () -> Void) {
        onOpen = open
        guard gestureRecognizers?.isEmpty ?? true else { return }
        isUserInteractionEnabled = true
        own.view = self
        addGestureRecognizer(InstantPan(target: self, action: #selector(pan(_:))))
    }

    @objc private func pan(_ pan: InstantPan) {
        let move = pan.translation
        switch pan.state {
        case .began:
            sideways = nil
        case .changed:
            if sideways == nil, max(abs(move.x), abs(move.y)) > 8 {
                sideways = abs(move.x) >= abs(move.y)
                if sideways == false { settle() }
            }
            if sideways != false { own.move(move.x) }
        case .ended:
            let side = sideways
            sideways = nil
            guard side == true else {
                settle()
                // Короткое касание или движение вверх открывает плеер.
                if side == nil || move.y < -36 { onOpen?() }
                return
            }
            let far = abs(move.x) > 50 || abs(pan.velocity.x) > 600
            own.release {
                guard far else { return }
                if move.x < 0 { Player.shared.next() } else { Player.shared.previous() }
            }
        case .cancelled, .failed:
            sideways = nil
            settle()
        default:
            break
        }
    }

    init(style: TrackPage.Style) {
        self.style = style
        front = TrackPage(style: style)
        back = TrackPage(style: style)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = style == .row
        back.isHidden = true
        addSubview(back)
        addSubview(front)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Шаг ленты. Обложка уезжает за край экрана целиком, строка мини-плеера — за край плашки.
    private var step: CGFloat {
        switch style {
        case .cover: return max(window?.bounds.width ?? UIScreen.main.bounds.width, bounds.width + 40)
        case .row: return bounds.width + 16
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for page in [front, back] {
            page.bounds = CGRect(origin: .zero, size: bounds.size)
            page.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private func shift(_ x: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: 0)
    }

    /// Где страница сейчас на экране, даже посреди анимации.
    private func place(of page: TrackPage) -> CGFloat {
        page.layer.presentation()?.affineTransform().tx ?? page.transform.tx
    }

    /// Останавливает движение, оставляя страницы там, где они сейчас видны.
    private func freeze() {
        let a = place(of: front)
        let b = place(of: back)
        front.layer.removeAllAnimations()
        back.layer.removeAllAnimations()
        front.transform = shift(a)
        back.transform = shift(b)
    }

    private func animate(_ changes: @escaping () -> Void) {
        run += 1
        let mine = run
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState], animations: changes
        ) { [weak self] done in
            guard let self, done, self.run == mine else { return }
            self.back.isHidden = true
        }
    }

    /// Исходное положение: играющий трек по центру, соседа не видно.
    private func rest() {
        run += 1
        front.layer.removeAllAnimations()
        back.layer.removeAllAnimations()
        front.transform = .identity
        back.transform = .identity
        back.isHidden = true
    }

    /// Вкладку с лентой убрали с экрана или вернули: анимация оборвалась, страницы встают на место.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        rest()
    }

    /// Первый показ: без движения.
    func set(_ track: Track?) {
        front.show(track)
    }

    /// Лента под пальцем: вместе с играющим треком едет соседний.
    func drag(_ x: CGFloat, neighbor: (Bool) -> Track?) {
        if run > 0, front.layer.animationKeys()?.isEmpty == false { freeze() }
        front.transform = shift(x)
        guard x != 0 else { return }
        let side = x < 0
        if back.isHidden || side != ahead {
            ahead = side
            let near = neighbor(side)
            back.show(near)
            back.isHidden = near == nil
        }
        back.transform = shift(x + (ahead ? step : -step))
    }

    /// Палец отпущен, трек не сменился: лента возвращается на место.
    func settle() {
        let away = ahead ? step : -step
        animate {
            self.front.transform = .identity
            self.back.transform = self.shift(away)
        }
    }

    /// Трек сменился: новый доезжает до центра оттуда, где стоит, прежний уезжает за край.
    func change(to track: Track, back goingBack: Bool) {
        guard track.id != front.track?.id else { return }
        // Лента не на экране (другая вкладка) или ещё без размера: двигать нечего.
        // Иначе прежний трек «уезжал» на пару точек и оставался лежать поверх нового.
        guard window != nil, bounds.width > 0 else {
            front.show(track)
            rest()
            return
        }
        freeze()
        let from = front.transform.tx
        let side = !goingBack
        // Сосед уже на экране и это тот самый трек — он продолжает движение со своего места.
        let ready = !back.isHidden && back.track?.id == track.id && ahead == side
        if !ready {
            back.show(track)
            back.isHidden = false
            back.transform = shift(from + (side ? step : -step))
        }
        swap(&front, &back)
        bringSubviewToFront(front)
        ahead = !side
        let away = side ? -step : step
        animate {
            self.front.transform = .identity
            self.back.transform = self.shift(away)
        }
    }
}

/// Жест, который начинается в момент касания и сразу сообщает сдвиг пальца.
final class InstantPan: UIGestureRecognizer {
    private(set) var translation: CGPoint = .zero
    private(set) var velocity: CGPoint = .zero
    private var start: CGPoint = .zero
    private var last: CGPoint = .zero
    private var stamp: TimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first else { return }
        start = touch.location(in: nil)
        last = start
        stamp = touch.timestamp
        translation = .zero
        velocity = .zero
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: nil)
        let passed = touch.timestamp - stamp
        if passed > 0 {
            velocity = CGPoint(x: (point.x - last.x) / passed, y: (point.y - last.y) / passed)
        }
        last = point
        stamp = touch.timestamp
        translation = CGPoint(x: point.x - start.x, y: point.y - start.y)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}

/// Связь жеста с лентой: жест живёт в SwiftUI, а двигается UIKit-слой напрямую, минуя
/// перерисовку экрана на каждое движение пальца.
@MainActor
final class TrackDrag: ObservableObject {
    weak var view: TrackPagerView?

    func move(_ x: CGFloat) {
        view?.drag(x) { ahead in
            let player = Player.shared
            let index = player.index + (ahead ? 1 : -1)
            return player.queue.indices.contains(index) ? player.queue[index] : nil
        }
    }

    /// Палец отпущен. `turn` переключает трек, если жест был достаточно длинным.
    func release(_ turn: () -> Void) {
        let before = Player.shared.current?.id
        turn()
        if let now = Player.shared.current, now.id != before {
            view?.change(to: now, back: Player.shared.movedBack)
        } else {
            view?.settle()
        }
    }
}

/// Лента треков в SwiftUI. Смену трека по кнопке или саму по себе она замечает по `track`.
struct TrackPager: UIViewRepresentable {
    let style: TrackPage.Style
    let track: Track?
    let drag: TrackDrag
    /// Если задано, лента сама ловит касания: нажатие и смахивание вверх открывают плеер.
    var onOpen: (() -> Void)?

    func makeUIView(context: Context) -> TrackPagerView {
        let view = TrackPagerView(style: style)
        view.set(track)
        drag.view = view
        if let onOpen { view.enableTouch(onOpen) }
        return view
    }

    func updateUIView(_ view: TrackPagerView, context: Context) {
        drag.view = view
        if let onOpen { view.enableTouch(onOpen) }
        guard let track else { return }
        if view.trackId == nil {
            view.set(track)
        } else if view.trackId != track.id {
            view.change(to: track, back: Player.shared.movedBack)
        }
    }
}
