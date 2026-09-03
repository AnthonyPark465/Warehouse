# Warehouse

An iPhone app for small businesses and warehouse owners to organize storage:
register products with photos and barcodes, scan items with the camera to see
what they are and how long they've been held, track daily incoming shipments,
and watch shelf life.

## Features

- **Products** — name, your own SKU, type, photo, shelf life, and a barcode.
- **Barcodes** — scan a product's existing barcode into the system, or generate
  a unique Code 128 barcode. A Firestore registry keyed by barcode value makes
  duplicates impossible, even from multiple devices.
- **Scanning** — point the camera (VisionKit) at any barcode to identify the
  product: stock on hand, days held, shelf life, expiry status. Unknown
  barcodes offer one-tap registration.
- **Batch tracking** — every arrival is a batch with its own received date and
  expiry. Removals consume the oldest stock first (FIFO).
- **Receiving & reports** — each day's arrivals form a shipment; the Reports
  tab shows units received per day, per product.
- **Sorting & grouping** — sort by newest, stock amount, or name; group by
  product type or by shipment.
- **Object scanning** — measure a product with native ARKit and optional LiDAR
  inside Add Product, apply configurable measurement tolerance and storage
  clearance, then review the object and storage bounding box in 3D.

## Stack

SwiftUI · iOS 17+ · Firebase (Auth + Firestore, free Spark plan — product
photos are stored as compressed thumbnails in Firestore, so no billing account
is ever needed). Bundle ID: `com.tetris.warehouse`.

## Getting started

0. **Prerequisites:** a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835)
   (16 or newer) and [Homebrew](https://brew.sh).
1. **Backend config** — one of:
   - **Joining an existing inventory?** Get `GoogleService-Info.plist` from
     whoever runs the Firebase project (it's gitignored on purpose — never
     commit it) and drop it into `WarehouseApp/`. Don't create a new Firebase
     project; you'd get a separate empty inventory.
   - **Setting up from scratch?** Follow [docs/firebase-setup.md](docs/firebase-setup.md)
     to create the free Firebase project, then drop the downloaded
     `GoogleService-Info.plist` into `WarehouseApp/`.
2. **Project file:** the Xcode project is generated — after changing
   `project.yml` or adding files, run:
   ```sh
   ./scripts/regen.sh
   ```
   (Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.)
3. **Build & test:**
   ```sh
   xcodebuild -project Warehouse.xcodeproj -scheme WarehouseApp \
     -destination 'platform=iOS Simulator,name=iPhone 15' test
   ```
4. **Run on an iPhone:**
   1. Open `Warehouse.xcodeproj`, add your Apple ID under Xcode → Settings →
      Accounts (a free account works), then select the WarehouseApp target →
      Signing & Capabilities → pick your **Team**.
   2. Plug in the iPhone (data cable, phone unlocked, tap **Trust**), enable
      **Developer Mode** on it (Settings → Privacy & Security), and select the
      phone in Xcode's device dropdown.
   3. Press **⌘R**. If macOS shows a *"codesign wants to access key…"*
      password prompt, enter your Mac password and click **Always Allow**.
   4. First launch only: on the phone, Settings → General → VPN & Device
      Management → trust your developer certificate, then open the app.
   5. Free Apple accounts: the install expires after 7 days — reconnect and
      press Run to refresh. In the app, **Create Account** once (any email +
      6-char password) or **Sign In** with the inventory's existing account.

## Project layout

```
WarehouseApp/
  App/        entry point, Firebase bootstrap, auth gate, tab shell
  Models/     Product, Batch, Shipment (immutable Codable structs)
  Services/   Firestore access, auth, photos, barcode registry, stock moves,
              shelf/space/placement persistence, LiDAR fusion + reconstruction
  Features/   Auth, Inventory, ProductDetail, AddProduct, Scan, Receive,
              Reports, Placement (AR storage measurement + placement engine)
  Support/    pure logic: expiry math, FIFO planning, batch corrections,
              sorting/grouping, barcode values, AR measurement geometry
WarehouseAppTests/  unit tests for the pure logic and geometry engines
```

The camera scanner only works on a real device; on the simulator the app
falls back to manual barcode entry everywhere scanning is offered.

Object measurement also requires a physical ARKit-capable device. LiDAR is
used when available; see [docs/object-scanning.md](docs/object-scanning.md) for
architecture, calibration limits, and physical-device testing.

Shelf-aware placement, explicit shelf-front capture, constraint ordering,
guidance, concurrency, limitations, and device testing are documented in
[docs/shelf-aware-placement.md](docs/shelf-aware-placement.md).
