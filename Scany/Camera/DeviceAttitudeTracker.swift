import CoreMotion
import Foundation

/// Tracks how the phone is held so a captured page can be saved with the same
/// "up" as the device, even though the UI is locked to portrait.
final class DeviceAttitudeTracker {
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.scany.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var gravityX: Double = 0
    private var gravityY: Double = -1
    private var gravityZ: Double = 0

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.08
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            self.lock.lock()
            self.gravityX = gravity.x
            self.gravityY = gravity.y
            self.gravityZ = gravity.z
            self.lock.unlock()
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Clockwise degrees to rotate a portrait camera image so its top matches
    /// the way the phone is currently held.
    var uprightRotationDegrees: CGFloat {
        lock.lock()
        let x = gravityX
        let y = gravityY
        let z = gravityZ
        lock.unlock()
        return Self.rotationDegrees(x: x, y: y, z: z)
    }

    static func rotationDegrees(x: Double, y: Double, z: Double) -> CGFloat {
        // Hovering over a desk, gravity is mostly through the screen. Keep the
        // camera image's top (notch) as up — that is the phone's own alignment.
        if abs(z) > 0.82, abs(x) < 0.4, abs(y) < 0.4 {
            return 0
        }
        if abs(y) >= abs(x) {
            return y <= 0 ? 0 : 180
        }
        return x > 0 ? 90 : 270
    }
}
