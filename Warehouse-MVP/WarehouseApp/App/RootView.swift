import SwiftUI

struct RootView: View {
    var body: some View {
        if FirebaseBootstrap.isConfigured {
            AuthGateView()
        } else {
            SetupRequiredView()
        }
    }
}

/// Shows the sign-in form until Firebase reports an authenticated user.
private struct AuthGateView: View {
    @State private var auth = AuthService()

    var body: some View {
        if auth.isSignedIn {
            MainTabView()
                .environment(auth)
        } else {
            SignInView(auth: auth)
        }
    }
}
