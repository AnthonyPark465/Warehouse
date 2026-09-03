import SwiftUI

struct InventoryListView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(AuthService.self) private var auth

    @State private var search = ""
    @State private var sort: InventorySort = .newestFirst
    @State private var grouping: InventoryGrouping = .none
    @State private var showsAddProduct = false
    @State private var showsSignOutConfirm = false
    @State private var productToDelete: Product?
    @State private var errorMessage: String?

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
                .confirmationDialog(
                    "Delete product?",
                    isPresented: .init(
                        get: { productToDelete != nil },
                        set: { if !$0 { productToDelete = nil } }
                    ),
                    presenting: productToDelete
                ) { product in
                    Button("Delete \(product.name) and All Stock", role: .destructive) {
                        delete(product)
                    }
                } message: { product in
                    Text("Deletes the product, its \(product.totalStock) units of stock, its photo, and frees its barcode for reuse. This can't be undone.")
                }
                .alert("Couldn't Delete", isPresented: .init(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Loading inventory…")
        } else if let loadError = store.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Inventory", systemImage: "wifi.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") { store.restart() }
                    .buttonStyle(.borderedProminent)
            }
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    productToDelete = product
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func delete(_ product: Product) {
        Task { @MainActor in
            do {
                try await ProductRepository.delete(product)
            } catch {
                errorMessage = error.localizedDescription
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
