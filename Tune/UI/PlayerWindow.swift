import SwiftUI
import UIKit

/// Полноэкранный плеер живёт в собственном окне поверх приложения.
///
/// Так он двигается целиком, одним слоем: под пальцем ничего не пересчитывается, кнопки
/// и меню не отстают от него, а нажатия не доходят до страницы, которая осталась под ним.
///
/// Двигается не само окно, а его содержимое: положение окна система выставляет сама
/// и сдвинутое окно возвращает на место по-своему.
@MainActor
final class PlayerWindow: ObservableObject {
    static let shared = PlayerWindow()

    @Published private(set) var visible = false
    private var window: UIWindow?
    /// Слой с плеером: его и возит палец.
    private var panel: UIView?
    /// На сколько плеер сейчас сдвинут вниз пальцем.
    private var offset: CGFloat = 0
    private var closing = false

    private init() {}

    private var height: CGFloat {
        (window?.bounds.height ?? UIScreen.main.bounds.height) + 40
    }

    func show(animated: Bool = true) {
        guard window == nil, Player.shared.current != nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            Log.shared.add("плеер: нет сцены для окна")
            return
        }

        let root = PlayerScreen()
            .environmentObject(Session.shared)
            .environmentObject(Player.shared)
            .environmentObject(Downloads.shared)
            .environmentObject(Router.shared)
            .environment(\.closePlayer, { PlayerWindow.shared.hide() })
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .preferredColorScheme(.dark)
            .tint(.white)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark

        // Плеер — дочерний экран прозрачного контейнера: контейнер стоит на месте,
        // а сдвигается только вложенный в него слой.
        let container = UIViewController()
        container.view.backgroundColor = .clear
        container.overrideUserInterfaceStyle = .dark
        container.addChild(host)
        host.view.frame = container.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.layer.cornerCurve = .continuous
        host.view.clipsToBounds = true
        container.view.addSubview(host.view)
        host.didMove(toParent: container)

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = container
        self.window = window
        panel = host.view
        offset = 0
        closing = false
        visible = true

        host.view.transform = CGAffineTransform(translationX: 0, y: height)
        window.isHidden = false
        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                host.view.transform = .identity
            }
        } else {
            host.view.transform = .identity
        }
    }

    /// Сдвиг под пальцем. Жест считает перемещение в координатах самого плеера, который
    /// едет вместе с пальцем, поэтому к нему прибавляется уже набранный сдвиг.
    func drag(_ local: CGFloat) {
        guard let panel, !closing else { return }
        offset = max(0, local + offset)
        panel.transform = CGAffineTransform(translationX: 0, y: offset)
        panel.layer.cornerRadius = offset > 0 ? 38 : 0
    }

    /// Палец отпущен: плеер либо уезжает вниз, либо возвращается на место.
    func release(predicted local: CGFloat) {
        guard let panel, !closing else { return }
        if offset > 140 || local + offset > 420 {
            hide()
            return
        }
        offset = 0
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            panel.transform = .identity
        } completion: { _ in
            if self.offset == 0 { panel.layer.cornerRadius = 0 }
        }
    }

    func hide() {
        guard let window, let panel, !closing else { return }
        closing = true
        let target = CGAffineTransform(translationX: 0, y: height)
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn]) {
            panel.transform = target
        } completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
            self.window = nil
            self.panel = nil
            self.offset = 0
            self.closing = false
            self.visible = false
        }
    }
}
