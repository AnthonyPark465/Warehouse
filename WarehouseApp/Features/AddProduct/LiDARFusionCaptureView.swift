import SwiftUI

struct LiDARFusionCaptureView: View {
    let onConfirm: (ObjectScanCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = false
    @State private var resetToken = 0
    @State private var status = ObjectScanLiveStatus()
    @State private var candidate: ObjectScanCapture?
    @State private var validationMessage: String?
    @State private var selection = ObjectScanSelectionSettings.smallObject

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                if ObjectScannerCapabilities.hasLiDAR {
                    ARObjectScannerView(
                        isScanning: isScanning,
                        resetToken: resetToken,
                        selectionSettings: selection,
                        onStatus: { status = $0 },
                        onCapture: acceptCapture
                    )
                    .ignoresSafeArea()
                    guide(in: geometry.size)
                    controls
                } else {
                    ContentUnavailableView(
                        "LiDAR unavailable",
                        systemImage: "sensor.tag.radiowaves.forward",
                        description: Text("This experimental mode requires a LiDAR-equipped Pro device.")
                    )
                }
                }
            }
            .navigationTitle("LiDAR Fusion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .alert("Rescan Required", isPresented: .init(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
            }
        }
    }

    private func guide(in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 24)
            .stroke(
                status.selectionIsLocked ? .green.opacity(0.95) : .cyan.opacity(0.95),
                style: StrokeStyle(lineWidth: 2, dash: status.selectionIsLocked ? [] : [10, 8])
            )
            .frame(
                width: size.width * CGFloat(selection.screenWidthFraction),
                height: size.height * CGFloat(selection.screenHeightFraction)
            )
            .overlay(alignment: .center) {
                Image(systemName: "plus")
                    .foregroundStyle(
                        status.selectionIsLocked ? .green.opacity(0.8) : .cyan.opacity(0.8)
                    )
            }
            .shadow(color: .black.opacity(0.4), radius: 2)
            .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        status.selectionIsLocked ? "World volume locked" : "Adjust selection",
                        systemImage: status.selectionIsLocked ? "lock.fill" : "viewfinder"
                    )
                    Spacer()
                    Text(status.confidence, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))

                Text(status.message)
                    .font(.footnote)

                HStack {
                    Text("\(status.integratedFrameCount) fused frames")
                    Spacer()
                    Text("\(status.pointCount) stable voxels")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                if status.rejectedPointCount > 0 {
                    Label(
                        "\(status.rejectedPointCount) outside-volume samples rejected",
                        systemImage: "rectangle.badge.xmark"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                }

                if let dimensions = status.dimensionsCM {
                    Text(
                        "\(format(dimensions.length)) × \(format(dimensions.width)) × \(format(dimensions.height)) cm"
                    )
                    .font(.headline.monospacedDigit())
                }

                if !status.selectionIsLocked && !isScanning {
                    selectionControls
                }

                Label(
                    status.selectionIsLocked
                        ? "The green 3D volume is fixed in the room. Keep other objects outside it."
                        : "Tighten both the screen box and 3D volume around only the target.",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack {
                    if isScanning {
                        Button("Finish Scan") { isScanning = false }
                            .buttonStyle(.borderedProminent)
                            .disabled(!status.canFinish)
                    } else if candidate == nil && !status.selectionIsLocked {
                        Button("Lock Selection & Start") { isScanning = true }
                            .buttonStyle(.borderedProminent)
                    }

                    Button("Reset Selection") {
                        candidate = nil
                        isScanning = false
                        resetToken += 1
                    }
                    .buttonStyle(.bordered)

                    if status.selectionIsLocked {
                        Button("Restart Scan") {
                            candidate = nil
                            isScanning = true
                            resetToken += 1
                        }
                        .buttonStyle(.bordered)
                    }

                    if let candidate {
                        Button("Confirm") {
                            onConfirm(candidate)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private var selectionControls: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                selectionSlider(
                    "Screen width",
                    value: $selection.screenWidthFraction,
                    range: 0.22...0.75
                )
                selectionSlider(
                    "Screen height",
                    value: $selection.screenHeightFraction,
                    range: 0.25...0.72
                )
                selectionSlider(
                    "Volume width \(centimetres(selection.volumeWidth)) cm",
                    value: $selection.volumeWidth,
                    range: 0.08...0.40
                )
                selectionSlider(
                    "Volume height \(centimetres(selection.volumeHeight)) cm",
                    value: $selection.volumeHeight,
                    range: 0.08...0.50
                )
                selectionSlider(
                    "Volume depth \(centimetres(selection.volumeDepth)) cm",
                    value: $selection.volumeDepth,
                    range: 0.08...0.40
                )
            }
            .padding(.trailing, 6)
        }
        .frame(height: 132)
        .scrollIndicators(.visible)
    }

    private func selectionSlider(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
            Slider(value: value, in: range)
        }
    }

    private func centimetres(_ metres: Float) -> String {
        Double(metres * 100).formatted(.number.precision(.fractionLength(0)))
    }

    private func acceptCapture(_ capture: ObjectScanCapture?, error: String?) {
        candidate = capture
        validationMessage = error
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
