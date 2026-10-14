#if os(iOS)
import UIKit

/// Draws a dot under every finger so screen recordings show where the user tapped.
/// The dots live in a separate window that ignores touches; a recognizer on the app's
/// window only watches touches and never claims them. Keyboard taps aren't shown,
/// since the keyboard has its own window.
@MainActor
final class TouchIndicator {
    static let shared = TouchIndicator()
    private var overlay: UIWindow?
    private var tracker: TouchTracker?

    func setEnabled(_ on: Bool) {
        if on {
            if !install() {
                // At launch the scene's window may not exist yet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = self.install() }
            }
        } else {
            if let tracker { tracker.view?.removeGestureRecognizer(tracker) }
            overlay?.isHidden = true
            overlay = nil
            tracker = nil
        }
    }

    private func install() -> Bool {
        guard overlay == nil else { return true }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let host = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return false }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        window.isHidden = false
        let tracker = TouchTracker(canvas: window)
        host.addGestureRecognizer(tracker)
        overlay = window
        self.tracker = tracker
        return true
    }
}

private final class TouchTracker: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var canvas: UIView?
    private var dots: [UITouch: UIView] = [:]

    init(canvas: UIView) {
        self.canvas = canvas
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
            dot.layer.cornerRadius = 19
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
            dot.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
            dot.layer.borderWidth = 1.5
            dot.isUserInteractionEnabled = false
            canvas?.addSubview(dot)
            dots[touch] = dot
            dot.center = touch.location(in: canvas)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { dots[touch]?.center = touch.location(in: canvas) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    override func reset() {
        super.reset()
        lift(Set(dots.keys))
    }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let dot = dots.removeValue(forKey: touch) else { continue }
            UIView.animate(withDuration: 0.25, animations: { dot.alpha = 0 }, completion: { _ in dot.removeFromSuperview() })
        }
        // Failing once every finger is up lets the recognizer reset for the next touch.
        if dots.isEmpty, state == .possible { state = .failed }
    }
}
#endif
