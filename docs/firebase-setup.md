# Firebase Setup (one-time, ~10 minutes, free — no credit card)

The app needs a Firebase project for sign-in and the inventory database.
Everything below stays on the free **Spark** plan.

## 1. Create the Firebase project

1. Go to <https://console.firebase.google.com> and sign in with your Google account.
2. Click **Create a project** (or "Add project"), name it e.g. `warehouse-inventory`.
3. Google Analytics is not needed — you can disable it. Create the project.

## 2. Enable Email/Password sign-in

1. In the left sidebar: **Build → Authentication → Get started**.
2. Under **Sign-in method**, choose **Email/Password**, toggle **Enable**, and Save.

## 3. Create the Firestore database

1. Sidebar: **Build → Firestore Database → Create database**.
2. Choose a location close to you (e.g. `us-central1` / `nam5`). Start in **production mode**.
3. Open the **Rules** tab, replace the contents with the rules below, and click **Publish**:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if request.auth != null;
    }
  }
}
```

This allows access only to signed-in users of your app. (Cloud Storage is
deliberately **not** used — product photos live inside Firestore, which keeps
the project on the free plan with no billing account.)

## 4. Register the iOS app and download the config file

1. On the project overview page, click the **iOS+** button to add an iOS app.
2. **Bundle ID:** `com.tetris.warehouse` (must match exactly).
3. Click **Register app**, then **Download GoogleService-Info.plist**.
4. Put the file at: `WarehouseApp/GoogleService-Info.plist` in this repo.
5. Regenerate the Xcode project so the file is bundled: `./scripts/regen.sh`
6. Build and run. The "Backend Not Configured" screen is replaced by sign-in.

> `GoogleService-Info.plist` is gitignored on purpose — it identifies your
> personal Firebase project and shouldn't be committed.

## 5. Create your account

In the app, switch to **Create Account**, enter an email and a password
(6+ characters). Everyone who signs in shares the same inventory in this
version, so only give the app to people you trust with your stock data.

## Running on your iPhone

1. Your iPhone runs iOS 18+, so **Xcode 16 is required** — update Xcode via the
   App Store first (your Mac currently has 15.4, which can only deploy to
   iOS 17.5 or older).
2. Open `Warehouse.xcodeproj`, select the **WarehouseApp** target → Signing &
   Capabilities → choose your **Team** (add your Apple ID under Xcode →
   Settings → Accounts if needed; a free account works).
3. Plug in the iPhone, enable **Developer Mode** on it
   (Settings → Privacy & Security → Developer Mode), select the device in
   Xcode's toolbar, and press **Run**.
4. First launch: trust the developer certificate on the phone
   (Settings → General → VPN & Device Management).

With a free Apple ID the install expires after 7 days — just press Run again
to reinstall. A paid developer account ($99/yr) removes that limit.
