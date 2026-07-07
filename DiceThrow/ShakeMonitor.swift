import CoreMotion
import Foundation

/// Shake-to-throw via the accelerometer, with a sensitivity threshold.
final class ShakeMonitor: ObservableObject {
    private let motion = CMMotionManager()
    private var lastSample: CMAcceleration?
    private var lastFiredAt = Date.distantPast
    private var threshold = 1.2

    var onShake: (() -> Void)?

    func start(sensitivity: String) {
        setSensitivity(sensitivity)
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 30.0
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            if let last = self.lastSample {
                let delta = abs(a.x - last.x) + abs(a.y - last.y) + abs(a.z - last.z)
                if delta > self.threshold, Date().timeIntervalSince(self.lastFiredAt) > 2.0 {
                    self.lastFiredAt = Date()
                    self.onShake?()
                }
            }
            self.lastSample = a
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        lastSample = nil
    }

    func setSensitivity(_ sensitivity: String) {
        switch sensitivity {
        case "low": threshold = 1.9      // needs a vigorous shake
        case "high": threshold = 0.65    // fires on a light flick
        default: threshold = 1.2
        }
    }
}
