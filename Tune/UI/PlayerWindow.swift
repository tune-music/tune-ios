import SwiftUI
import UIKit

/// Полноэкранный плеер живёт в собственном окне поверх приложения.
///
/// Так он двигается целиком, одним слоем: под пальцем ничего не пересчитывается, кнопки
/// и меню не отстают от него, а нажатия не доходят до страницы, которая осталась под ним.
@MainActor
final class PlayerWindow: ObservableObject {
    static let shared = PlayerWindow()

    @Published private(set) var visible = false
    private var window: UIWindow?
    /// На сколько плеер сейчас сдвинут вниз пальцем.
    private var offset: CGFloat = 0
    private var closing = false

    private init() {}

    private var height: CGFloat {
        (window?.bounds.height ?? UIScreen.main.bounds.height) + 40
    }

    func show(animated: Bool = true) {
        if Demo.on { NSLog("TUNE-PW show: window=%d current=%d scenes=%d", window == nil ? 0 : 1, Player.shared.current == nil ? 0 : 1, UIApplication.shared.connectedScenes.count) }
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

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.layer.cornerCurve = .continuous
        window.clipsToBounds = true
        window.frame = scene.coordinateSpace.bounds
        self.window = window
        window.transform = CGAffineTransform(translationX: 0, y: height)
        window.makeKeyAndVisible()
        if Demo.on {
            NSLog("TUNE-PW shown: frame=%@ hidden=%d level=%f windows=%d", NSCoder.string(for: window.frame), window.isHidden ? 1 : 0, Double(window.windowLevel.rawValue), scene.windows.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let window = self?.window else { NSLog("TUNE-PW later: window gone"); return }
                NSLog("TUNE-PW later: frame=%@ hidden=%d alpha=%f tx=%f ty=%f root=%@ sub=%d", NSCoder.string(for: window.frame), window.isHidden ? 1 : 0, Double(window.alpha), Double(window.transform.tx), Double(window.transform.ty), NSCoder.string(for: window.rootViewController?.view.frame ?? .zero), window.subviews.count)
            }
        }
        offset = 0
        closing = false
        visible = true

        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                window.transform = .identity
            }
        } else {
            window.transform = .identity
        }
    }

    /// Сдвиг под пальцем. Жест считает перемещение в координатах самого плеера, который
    /// едет вместе с пальцем, поэтому к нему прибавляется уже набранный сдвиг.
    func drag(_ local: CGFloat) {
        guard let window, !closing else { return }
        offset = max(0, local + offset)
        window.transform = CGAffineTransform(translationX: 0, y: offset)
        window.layer.cornerRadius = offset > 0 ? 38 : 0
    }

    /// Палец отпущен: плеер либо уезжает вниз, либо возвращается на место.
    func release(predicted local: CGFloat) {
        guard let window, !closing else { return }
        if offset > 140 || local + offset > 420 {
            hide()
            return
        }
        offset = 0
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            window.transform = .identity
        } completion: { _ in
            if self.offset == 0 { window.layer.cornerRadius = 0 }
        }
    }

    func hide() {
        guard let window, !closing else { return }
        closing = true
        let target = CGAffineTransform(translationX: 0, y: height)
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn]) {
            window.transform = target
        } completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
            self.window = nil
            self.offset = 0
            self.closing = false
            self.visible = false
        }
    }
}
