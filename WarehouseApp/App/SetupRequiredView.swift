import SwiftUI

/// Shown when the app is built without a GoogleService-Info.plist,
/// which happens before the Firebase project has been set up.
struct SetupRequiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Backend Not Configured")
                .font(.title2.bold())
            Text("Add GoogleService-Info.plist from your Firebase project to the WarehouseApp folder, then rebuild. See docs/firebase-setup.md for step-by-step instructions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
