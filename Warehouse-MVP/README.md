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
- **LiDAR shelf placement MVP** — measure horizontal shelf footprints on a
  LiDAR-equipped iPhone, eliminate locations that fail package size or weight
  constraints, rank the remaining locations using travel distance, order
  affinity, space efficiency, demand velocity, and business scale, then verify
  the move by scanning the product followed by the location barcode.

## Stack

SwiftUI · iOS 17+ · Firebase (Auth + Firestore, free Spark plan — product
photos are stored as compressed thumbnails in Firestore, so no billing account
is ever needed). Bundle ID: `com.tetris.warehouse`.

The LiDAR placement flow is an operational aid, not a structural-safety tool.
The scan measures visible shelf footprint. Clear height, rated load, existing
occupancy, and permanent location barcodes must come from maintained warehouse
master data before production use.

## Getting started

1. **Backend:** follow [docs/firebase-setup.md](docs/firebase-setup.md) to
   create the free Firebase project and drop `GoogleService-Info.plist` into
   `WarehouseApp/`.
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
4. **Run on an iPhone:** see the device section at the end of
   [docs/firebase-setup.md](docs/firebase-setup.md).

## Project layout

```
WarehouseApp/
  App/        entry point, Firebase bootstrap, auth gate, tab shell
  Models/     Product, Batch, Shipment (immutable Codable structs)
  Services/   Firestore access, auth, photos, barcode registry, stock moves
  Features/   Auth, Inventory, ProductDetail, AddProduct, Scan, Receive, Reports
  Support/    pure logic: expiry math, FIFO planning, sorting/grouping, barcode values
WarehouseAppTests/  unit tests for all the pure logic
```

The camera scanner only works on a real device; on the simulator the app
falls back to manual barcode entry everywhere scanning is offered.
