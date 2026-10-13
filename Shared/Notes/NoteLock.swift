import Foundation
import LocalAuthentication

/// Asks who is at the Mac before a locked note is shown: Touch ID — or the Apple Watch, or the
/// session's password when the Mac has no Touch ID or the finger isn't recognized. macOS shows
/// the dialog; the app never sees a fingerprint or a password.
///
/// The lock is one of display: the note's file stays plain text in the app's container.
enum NoteLock {
    /// `reason` completes "Void Notes tente de…". `completion` is called on the main thread.
    typealias Authenticator = (_ reason: String, _ completion: @escaping @MainActor (Bool) -> Void) -> Void

    /// Neither Touch ID nor a password on this Mac: a locked note could never be opened again.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// What opens a locked note on this Mac, as said in the interface: Touch ID when it has it
    /// and a finger is enrolled, the password of the session otherwise.
    static var method: String {
        let context = LAContext()
        let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        #if os(macOS)
        return biometrics ? "Touch ID" : "le mot de passe du Mac"
        #else
        return !biometrics ? "le code de l'iPhone" : context.biometryType == .touchID ? "Touch ID" : "Face ID"
        #endif
    }

    static func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Annuler"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } }
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(success) } }
        }
    }
}
