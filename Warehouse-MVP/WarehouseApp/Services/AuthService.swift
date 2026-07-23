import FirebaseAuth
import Foundation
import Observation

@Observable
final class AuthService {
    private(set) var user: FirebaseAuth.User?
    private var listener: AuthStateDidChangeListenerHandle?

    var isSignedIn: Bool { user != nil }

    init() {
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.user = user
        }
    }

    deinit {
        if let listener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }

    func signIn(email: String, password: String) async throws {
        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            throw AuthError(wrapping: error)
        }
    }

    func signUp(email: String, password: String) async throws {
        do {
            try await Auth.auth().createUser(withEmail: email, password: password)
        } catch {
            throw AuthError(wrapping: error)
        }
    }

    func signOut() throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw AuthError(wrapping: error)
        }
    }
}

/// Wraps FirebaseAuth errors with messages suitable for an alert.
struct AuthError: LocalizedError {
    let message: String

    init(wrapping error: Error) {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .invalidEmail:
            message = "That email address doesn't look valid."
        case .emailAlreadyInUse:
            message = "An account already exists for that email. Try signing in instead."
        case .weakPassword:
            message = "Password is too weak — use at least 6 characters."
        case .wrongPassword, .invalidCredential, .userNotFound:
            message = "Email or password is incorrect."
        case .networkError:
            message = "No connection. Check your internet and try again."
        case .tooManyRequests:
            message = "Too many attempts. Please wait a moment and try again."
        default:
            message = error.localizedDescription
        }
    }

    var errorDescription: String? { message }
}
