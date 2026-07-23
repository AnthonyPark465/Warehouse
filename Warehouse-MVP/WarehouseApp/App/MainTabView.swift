import SwiftUI

struct MainTabView: View {
    @State private var store = InventoryStore()

    var body: some View {
        TabView {
            InventoryListView()
                .tabItem { Label("Inventory", systemImage: "shippingbox") }
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            PlacementView()
                .tabItem { Label("Place", systemImage: "square.3.layers.3d") }
            ReceiveView()
                .tabItem { Label("Receive", systemImage: "tray.and.arrow.down") }
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar") }
        }
        .environment(store)
        .onAppear { store.start() }
    }
}
