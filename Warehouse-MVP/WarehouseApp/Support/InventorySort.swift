import Foundation

enum InventorySort: String, CaseIterable, Identifiable {
    case newestFirst
    case stockHighFirst
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newestFirst: "Newest"
        case .stockHighFirst: "Stock"
        case .name: "Name"
        }
    }

    func sorted(_ products: [Product]) -> [Product] {
        switch self {
        case .newestFirst:
            products.sorted { ($0.lastReceivedAt ?? $0.createdAt) > ($1.lastReceivedAt ?? $1.createdAt) }
        case .stockHighFirst:
            products.sorted {
                $0.totalStock == $1.totalStock
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.totalStock > $1.totalStock
            }
        case .name:
            products.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

enum InventoryGrouping: String, CaseIterable, Identifiable {
    case none
    case byType
    case byShipment

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No Grouping"
        case .byType: "By Type"
        case .byShipment: "By Shipment"
        }
    }
}

struct ProductGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let products: [Product]
}

enum InventoryGrouper {
    static func groupByType(_ products: [Product]) -> [ProductGroup] {
        Dictionary(grouping: products, by: \.type)
            .map { ProductGroup(id: $0.key, title: $0.key, products: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Groups products under each day's shipment they arrived in, newest day first.
    /// A product appears in every shipment group it has a batch in.
    static func groupByShipment(_ products: [Product], batches: [Batch]) -> [ProductGroup] {
        let productsById = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return Dictionary(grouping: batches, by: \.shipmentId)
            .map { shipmentId, shipmentBatches in
                let uniqueProductIds = Set(shipmentBatches.map(\.productId))
                let members = uniqueProductIds
                    .compactMap { productsById[$0] }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return ProductGroup(id: shipmentId, title: shipmentId, products: members)
            }
            .sorted { $0.id > $1.id }
    }
}
