import SwiftUI

/// Daily receiving report, computed live from the batch listener:
/// one section per shipment day, newest first, with per-product breakdown.
struct ReportsView: View {
    @Environment(InventoryStore.self) private var store

    private struct DayReport: Identifiable {
        let id: String
        let totalUnits: Int
        let lines: [(productId: String, units: Int)]
    }

    private var reports: [DayReport] {
        Dictionary(grouping: store.batches, by: \.shipmentId)
            .map { shipmentId, batches in
                let byProduct = Dictionary(grouping: batches, by: \.productId)
                    .map { (productId: $0.key, units: $0.value.reduce(0) { $0 + $1.quantity }) }
                    .sorted { $0.units > $1.units }
                return DayReport(
                    id: shipmentId,
                    totalUnits: batches.reduce(0) { $0 + $1.quantity },
                    lines: byProduct
                )
            }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    ContentUnavailableView(
                        "No Reports Yet",
                        systemImage: "chart.bar",
                        description: Text("Receive stock and each day's intake will show up here.")
                    )
                } else {
                    List {
                        ForEach(reports) { report in
                            Section("\(formattedDay(report.id)) — \(report.totalUnits) units in") {
                                ForEach(report.lines, id: \.productId) { line in
                                    HStack {
                                        Text(productName(for: line.productId))
                                        Spacer()
                                        Text("+\(line.units)")
                                            .font(.body.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reports")
        }
    }

    private func productName(for productId: String) -> String {
        store.products.first { $0.id == productId }?.name ?? "Unknown product"
    }

    private func formattedDay(_ dateKey: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateKey) else { return dateKey }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
