import SwiftUI

struct InventoryListView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(AuthService.self) private var auth

    @State private var search = ""
    @State private var sort: InventorySort = .newestFirst
    @State private var grouping: InventoryGrouping = .none
    @State private var showsAddProduct = false
    @State private var showsSignOutConfirm = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Inventory")
                .searchable(text: $search, prompt: "Name, code, or barcode")
                .toolbar { toolbarContent }
                .sheet(isPresented: $showsAddProduct) { AddProductView() }
                .navigationDestination(for: String.self) { productId in
                    ProductDetailView(productId: productId)
                }
                .confirmationDialog("Sign out?", isPresented: $showsSignOutConfirm) {
                    Button("Sign Out", role: .destructive) { try? auth.signOut() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Loading inventory…")
        } else if let loadError = store.loadError {
            ContentUnavailableView("Couldn't Load Inventory", systemImage: "wifi.slash", description: Text(loadError))
        } else if store.products.isEmpty {
            ContentUnavailableView {
                Label("No Products Yet", systemImage: "shippingbox")
            } description: {
                Text("Register your first product to start tracking stock.")
            } actions: {
                Button("Add Product") { showsAddProduct = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            productList
        }
    }

    private var filteredProducts: [Product] {
        let base: [Product]
        if search.isEmpty {
            base = store.products
        } else {
            let query = search.lowercased()
            base = store.products.filter {
                $0.name.lowercased().contains(query)
                    || $0.productCode.lowercased().contains(query)
                    || ($0.barcode?.lowercased().contains(query) ?? false)
            }
        }
        return sort.sorted(base)
    }

    private var productList: some View {
        List {
            switch grouping {
            case .none:
                rows(filteredProducts)
            case .byType:
                ForEach(InventoryGrouper.groupByType(filteredProducts)) { group in
                    Section(group.title) { rows(sort.sorted(group.products)) }
                }
            case .byShipment:
                ForEach(InventoryGrouper.groupByShipment(filteredProducts, batches: store.batches)) { group in
                    Section("Shipment \(group.title)") { rows(sort.sorted(group.products)) }
                }
            }
        }
    }

    private func rows(_ products: [Product]) -> some View {
        ForEach(products) { product in
            NavigationLink(value: product.id) {
                ProductRow(product: product)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showsSignOutConfirm = true
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityLabel("Sign Out")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(InventorySort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Group", selection: $grouping) {
                    ForEach(InventoryGrouping.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort and Group")

            Button {
                showsAddProduct = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Product")
        }
    }
}
