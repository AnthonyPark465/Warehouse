import SwiftUI

struct ManualDimensionEntryView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var canBeRotated: Bool
    let onSave: (ObjectScanCapture) -> Void

    @State private var length = ""
    @State private var width = ""
    @State private var height = ""
    @State private var unit: DimensionDisplayUnit = .centimetres

    var body: some View {
        NavigationStack {
            Form {
                Section("Dimensions") {
                    Picker("Unit", selection: $unit) {
                        ForEach(DimensionDisplayUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    dimensionField("Length", text: $length)
                    dimensionField("Width", text: $width)
                    dimensionField("Height", text: $height)
                }
                Section("Storage") {
                    Toggle("Can this product be rotated for storage?", isOn: $canBeRotated)
                }
            }
            .navigationTitle("Manual Dimensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(values == nil)
                }
            }
        }
    }

    private func dimensionField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
            Text(unit.rawValue).foregroundStyle(.secondary)
        }
    }

    private var values: ObjectDimensions? {
        guard let length = Double(length.replacingOccurrences(of: ",", with: ".")),
              let width = Double(width.replacingOccurrences(of: ",", with: ".")),
              let height = Double(height.replacingOccurrences(of: ",", with: ".")),
              length > 0, width > 0, height > 0
        else { return nil }
        let multiplier = unit == .metres ? 100.0 : 1.0
        let dimensions = ObjectDimensions(
            length: length * multiplier,
            width: width * multiplier,
            height: height * multiplier
        )
        return dimensions.values.allSatisfy { $0 <= ObjectScanValidation.maximumDimensionCM }
            ? dimensions : nil
    }

    private func apply() {
        guard let values else { return }
        onSave(ObjectScanCapture(
            id: UUID(),
            rawDimensionsCM: values,
            pointsInMetres: [],
            scanMethod: .manualEntry,
            deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
            hasLiDAR: ObjectScannerCapabilities.hasLiDAR,
            confidence: 1,
            timestamp: .now
        ))
        // Dismiss only this sheet. The presenter must not tear down its own
        // container inside onSave — it applies the capture from the sheet's
        // onDismiss, so the two dismissals can never race (D15).
        dismiss()
    }
}
