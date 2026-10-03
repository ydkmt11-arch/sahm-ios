import LocalAuthentication
import UIKit

/// Optional lock: Face ID / Touch ID, falling back to the phone's passcode. Switched on from the «المزيد» screen;
/// off by default.
final class LockGate {
    static let shared = LockGate()
    private let key = "sahm.lock"

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// "faceID", "touchID", "passcode", or "none" (no passcode on the phone: nothing to lock with).
    var kind: String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch context.biometryType {
            case .faceID: return "faceID"
            case .touchID: return "touchID"
            default: return "passcode"
            }
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? "passcode" : "none"
    }

    func authenticate(reason: String, done: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "إلغاء"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}
