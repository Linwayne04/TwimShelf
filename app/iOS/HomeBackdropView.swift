import UIKit
import CoreMotion

/// Home screen background: a soft light-to-blue wash with a halftone of tiny four-point stars
/// that grow denser toward the lower right, gently shifting with the device's tilt.
///
/// Kept cheap on purpose: the accelerometer (no gyroscope) at 15 Hz, low-pass filtered; the
/// layers move only when the change is visible (≥ 0.3 pt), so a phone lying still costs no
/// redraws at all; the halftone is drawn once per size into one bitmap. Sensors run only while
/// the home screen is visible, the app is active, the setting is on, Reduce Motion and Low Power
/// Mode are off. Turned off in Settings, the view is hidden and its bitmap released.
final class HomeBackdropView: UIView {
    private let gradient = CAGradientLayer()
    private let dots = CALayer()
    private let motion = CMMotionManager()
    private var dotsImageSize: CGSize = .zero
    private var smoothed = CGPoint.zero
    private var applied = CGPoint.zero
    /// Set by the owner: the home screen is on screen.
    var visible = false { didSet { updateMotion() } }
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(gradient)
        layer.addSublayer(dots)
        gradient.type = .axial
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: HomeBackdropView, _) in v.applyColors(); v.dotsImageSize = .zero; v.setNeedsLayout() }
        let nc = NotificationCenter.default
        for n in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                  UIAccessibility.reduceMotionStatusDidChangeNotification, LibraryPrefs.changed] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.settingsChanged() } })
        }
        settingsChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func settingsChanged() {
        let on = LibraryPrefs.backdrop
        if isHidden == on {
            isHidden = !on
            if !on { dots.contents = nil; dotsImageSize = .zero } else { setNeedsLayout() }
        }
        updateMotion()
    }

    private var motionAllowed: Bool {
        LibraryPrefs.backdrop && visible && !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && UIApplication.shared.applicationState == .active && motion.isAccelerometerAvailable
    }

    private func updateMotion() {
        if motionAllowed { startMotion() } else { stopMotion() }
    }

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func applyColors() {
        gradient.colors = isDark
            ? [UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1), UIColor(red: 0.08, green: 0.11, blue: 0.22, alpha: 1), UIColor(red: 0.12, green: 0.2, blue: 0.45, alpha: 1)].map(\.cgColor)
            : [UIColor(white: 0.975, alpha: 1), UIColor(red: 0.9, green: 0.93, blue: 0.99, alpha: 1), UIColor(red: 0.55, green: 0.66, blue: 0.95, alpha: 1)].map(\.cgColor)
        gradient.locations = [0, 0.45, 1]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // oversized so tilting never shows an edge
        let pad: CGFloat = 40
        gradient.frame = bounds.insetBy(dx: -pad, dy: -pad)
        dots.frame = bounds.insetBy(dx: -pad, dy: -pad)
        CATransaction.commit()
        updateGradient(tilt: smoothed)
        if !isHidden, dots.bounds.size != dotsImageSize, dots.bounds.width > 0 {
            dotsImageSize = dots.bounds.size
            dots.contents = Self.halftone(size: dotsImageSize, dark: isDark, scale: window?.screen.scale ?? 2).cgImage
        }
    }

    private func updateGradient(tilt: CGPoint) {
        // the light area drifts a little with the tilt
        gradient.startPoint = CGPoint(x: 0.2 + tilt.x * 0.12, y: 0.0 + tilt.y * 0.10)
        gradient.endPoint = CGPoint(x: 0.85 + tilt.x * 0.12, y: 1.0 + tilt.y * 0.10)
    }

    /// Diamond "stars" on a grid; their size follows a diagonal ramp (none at the upper left,
    /// largest at the lower right), like printed halftone.
    private static func halftone(size: CGSize, dark: Bool, scale: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = min(scale, 2)
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let color = dark ? UIColor(red: 0.45, green: 0.6, blue: 1, alpha: 0.35) : UIColor(red: 0.2, green: 0.38, blue: 0.9, alpha: 0.5)
            c.setFillColor(color.cgColor)
            let step: CGFloat = 7
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : step / 2
                while x < size.width {
                    let t = (x / size.width) * 0.55 + (y / size.height) * 0.75 - 0.45   // diagonal ramp
                    let r = max(0, min(1, t)) * step * 0.42
                    if r > 0.35 {
                        // four-point star: a diamond with pinched sides
                        let p = UIBezierPath()
                        p.move(to: CGPoint(x: x, y: y - r))
                        p.addQuadCurve(to: CGPoint(x: x + r, y: y), controlPoint: CGPoint(x: x + r * 0.22, y: y - r * 0.22))
                        p.addQuadCurve(to: CGPoint(x: x, y: y + r), controlPoint: CGPoint(x: x + r * 0.22, y: y + r * 0.22))
                        p.addQuadCurve(to: CGPoint(x: x - r, y: y), controlPoint: CGPoint(x: x - r * 0.22, y: y + r * 0.22))
                        p.addQuadCurve(to: CGPoint(x: x, y: y - r), controlPoint: CGPoint(x: x - r * 0.22, y: y - r * 0.22))
                        c.addPath(p.cgPath)
                    }
                    x += step
                }
                c.fillPath()
                y += step * 0.87
                row += 1
            }
        }
    }

    // MARK: Motion

    private func startMotion() {
        guard !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 15
        motion.startAccelerometerUpdates(to: .main) { [weak self] d, _ in
            guard let self, let a = d?.acceleration else { return }
            // gravity in −1…1 (the accelerometer's low-passed signal); drifts, never jitters
            self.smoothed.x += (CGFloat(a.x) - self.smoothed.x) * 0.12
            self.smoothed.y += (CGFloat(a.y) + 0.6 - self.smoothed.y) * 0.12
            // move only when the shift is visible: a phone lying still costs no redraws
            guard abs(self.smoothed.x - self.applied.x) * 24 >= 0.3 || abs(self.smoothed.y - self.applied.y) * 18 >= 0.3 else { return }
            self.applied = self.smoothed
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.updateGradient(tilt: self.smoothed)
            // the halftone moves opposite to the tilt (parallax), at most ±24 pt
            self.dots.setAffineTransform(CGAffineTransform(translationX: -self.smoothed.x * 24, y: -self.smoothed.y * 18))
            CATransaction.commit()
        }
    }

    private func stopMotion() { if motion.isAccelerometerActive { motion.stopAccelerometerUpdates() } }
}
