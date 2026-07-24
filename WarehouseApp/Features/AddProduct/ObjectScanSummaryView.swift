import SwiftUI

struct ObjectScanSummaryView: View {
    let capture: ObjectScanCapture
    @Binding var displayUnit: DimensionDisplayUnit
    @Binding var canBeRotated: Bool
    let onRescan: () -> Void

    @State private var resetCameraToken = 0

    private var record: ProductObjectScan {
        ObjectDimensionCalculator.makeRecord(
            capture: capture,
            displayUnit: displayUnit,
            canBeRotated: canBeRotated
        )
    }

    var body: some View {
        Section("Object Scan") {
            Picker("Display Unit", selection: $displayUnit) {
                ForEach(DimensionDisplayUnit.allCases) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.segmented)

            dimensionGroup(
                title: "Raw Dimensions",
                dimensions: ObjectDimensions(
                    length: record.rawLength,
                    width: record.rawWidth,
                    height: record.rawHeight
                )
            )
            dimensionGroup(
                title: "Scan Tolerance",
                dimensions: ObjectDimensions(
                    length: record.scanToleranceLength,
                    width: record.scanToleranceWidth,
                    height: record.scanToleranceHeight
                )
            )
            dimensionGroup(
                title: "Storage Clearance",
                dimensions: ObjectDimensions(
                    length: record.storageClearanceLength,
                    width: record.storageClearanceWidth,
                    height: record.storageClearanceHeight
                )
            )
            dimensionGroup(
                title: "Final Storage Dimensions",
                dimensions: ObjectDimensions(
                    length: record.finalLength,
                    width: record.finalWidth,
                    height: record.finalHeight
                ),
                emphasized: true
            )

            Toggle("Item can be rotated during storage", isOn: $canBeRotated)

            VStack(alignment: .leading, spacing: 8) {
                ObjectScanViewer(
                    capture: capture,
                    record: record,
                    displayUnit: displayUnit,
                    resetCameraToken: resetCameraToken
                )
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Scanned object inside storage bounding box")

                HStack {
                    Label("Drag to rotate · pinch to zoom · two-finger drag to pan", systemImage: "hand.draw")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Camera") { resetCameraToken += 1 }
                        .font(.caption)
                }
            }

            LabeledContent("Scan Confidence") {
                HStack(spacing: 6) {
                    Image(systemName: confidenceSymbol)
                        .foregroundStyle(confidenceColor)
                    Text(capture.confidence, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            LabeledContent(
                "Scan Method",
                value: scanMethodName
            )

            Button("Rescan Object", action: onRescan)
        }
    }

    private func dimensionGroup(
        title: String,
        dimensions: ObjectDimensions,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(emphasized ? .bold : .semibold))
            dimensionLine("Length", dimensions.length, emphasized: emphasized)
            dimensionLine("Width", dimensions.width, emphasized: emphasized)
            dimensionLine("Height", dimensions.height, emphasized: emphasized)
        }
        .padding(.vertical, 2)
    }

    private func dimensionLine(_ name: String, _ valueCM: Double, emphasized: Bool) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(DimensionUnitConverter.formatted(valueCM, unit: displayUnit))
                .font(.body.monospacedDigit().weight(emphasized ? .semibold : .regular))
        }
    }

    private var confidenceSymbol: String {
        capture.confidence >= 0.8 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var confidenceColor: Color {
        capture.confidence >= 0.8 ? .green : .orange
    }

    private var scanMethodName: String {
        switch capture.scanMethod {
        case .objectCapture:
            "Apple Object Capture"
        case .lidar:
            "Multi-frame LiDAR Fusion"
        case .standardAR:
            "Standard ARKit"
        }
    }
}
