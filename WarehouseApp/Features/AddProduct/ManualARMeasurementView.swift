import SwiftUI

struct ManualARMeasurementView: View {
    let onConfirm: (ObjectScanCapture, Double, Double, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = ManualARMeasurementState()
    @State private var showsManualEntry = false

    var body: some View {
        NavigationStack {
            ZStack {
                if ObjectScannerCapabilities.isSupported {
                    ManualARSessionView(state: state).ignoresSafeArea()
                    if state.stage != .review {
                        centreTarget
                    }
                    interface
                } else {
                    unsupportedView
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden()
            .alert("Measurement Problem", isPresented: .init(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )) {
                Button("Try Again", role: .cancel) {}
                Button("Restart") { state.reset() }
                Button("Enter Manually") { showsManualEntry = true }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .sheet(isPresented: $showsManualEntry) {
                ManualDimensionEntryView(
                    canBeRotated: $state.canBeRotated,
                    onSave: { capture in
                        onConfirm(
                            capture,
                            state.percentageTolerance,
                            state.fixedToleranceCM,
                            state.canBeRotated,
                            state.useAdjustedDimensions
                        )
                        dismiss()
                    }
                )
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    state.errorMessage = "Measurement paused while the app was in the background. Verify that every marker is still aligned before continuing."
                }
            }
        }
    }

    private var interface: some View {
        VStack(spacing: 0) {
            topPanel
            Spacer()
            if state.stage == .review {
                reviewPanel
            } else {
                controls
            }
        }
        .safeAreaPadding()
    }

    private var topPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                Spacer()
                Text(state.stage.rawValue)
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }

            VStack(spacing: 5) {
                Text(state.stage.instruction)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Label(state.trackingMessage, systemImage: state.trackingIsNormal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(state.trackingIsNormal ? .green : .orange)
                if !ObjectScannerCapabilities.hasLiDAR {
                    Text("LiDAR unavailable—standard ARKit estimates may be less accurate.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var centreTarget: some View {
        ZStack {
            Circle()
                .stroke(state.currentSample == nil ? .white : .green, lineWidth: 3)
                .frame(width: 26, height: 26)
            Circle()
                .fill(state.currentSample == nil ? .white : .green)
                .frame(width: 5, height: 5)
        }
        .shadow(radius: 2)
        .accessibilityLabel(state.currentSample == nil ? "No surface detected" : "Valid surface detected")
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text(state.markerCountText)
                    .font(.caption.monospacedDigit())
                Spacer()
                if let sample = state.currentSample {
                    Text("\(sample.cameraDistanceMetres.formatted(.number.precision(.fractionLength(2)))) m away")
                        .font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 18) {
                Button("Undo") { state.undo() }
                    .disabled(state.boundaryMarkers.isEmpty && state.bottomMarker == nil && state.topMarker == nil)
                Button("Reset", role: .destructive) { state.reset() }
                Spacer()
                primaryAction
            }
            .buttonStyle(.bordered)
            .tint(.white)

            if state.stage == .boundary, state.boundaryMarkers.count >= 3 {
                Button("Close Boundary") { state.closeBoundary() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else if state.stage == .confirmBase {
                Button("Confirm Base") { state.confirmBase() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state.stage {
        case .boundary:
            Button {
                state.requestPlacement()
            } label: {
                placeButtonLabel("Place")
            }
            .disabled(!state.canPlace)
        case .bottom:
            Button {
                state.requestPlacement()
            } label: {
                placeButtonLabel("Place Bottom")
            }
            .disabled(!state.canPlace)
        case .top:
            Button {
                state.requestPlacement()
            } label: {
                placeButtonLabel("Place Top")
            }
            .disabled(!state.canPlace)
        default:
            EmptyView()
        }
    }

    private func placeButtonLabel(_ title: String) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(state.canPlace ? .white : .gray)
                .frame(width: 54, height: 54)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 2).padding(4))
            Text(title).font(.caption.weight(.semibold))
        }
    }

    private var reviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AR measurements are estimates. Verify high-precision inventory with a tape measure.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                if let raw = state.rawDimensionsCM,
                   let boundary = state.boundaryMeasurement {
                    reviewDimensions("Measured", raw)
                    reviewDimensions("Storage after tolerance", adjusted(raw))
                    LabeledContent("Footprint area") {
                        Text("\((boundary.footprint.areaSquareMetres * 10_000).formatted(.number.precision(.fractionLength(2)))) cm²")
                    }
                    LabeledContent("Quality", value: qualityName)
                    LabeledContent("LiDAR", value: ObjectScannerCapabilities.hasLiDAR ? "Available" : "Unavailable")
                }

                Group {
                    HStack {
                        Text("Tolerance")
                        Slider(value: $state.percentageTolerance, in: 0...0.10, step: 0.005)
                        Text(state.percentageTolerance, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Fixed")
                        Slider(value: $state.fixedToleranceCM, in: 0...5, step: 0.1)
                        Text("\(state.fixedToleranceCM.formatted(.number.precision(.fractionLength(1)))) cm")
                            .monospacedDigit()
                    }
                    Toggle("Can this product be rotated for storage?", isOn: $state.canBeRotated)
                    Toggle("Use adjusted dimensions for storage", isOn: $state.useAdjustedDimensions)
                }

                DisclosureGroup("Replace a measurement") {
                    ForEach(Array(state.boundaryMarkers.enumerated()), id: \.element.id) { index, _ in
                        Button("Replace base point \(index + 1)") {
                            state.replaceBoundaryPoint(at: index)
                        }
                    }
                    Button("Replace bottom point") { state.replaceBottom() }
                    Button("Replace top point") { state.replaceTop() }
                }

                HStack {
                    Button("Restart", role: .destructive) { state.reset() }
                    Button("Enter Manually") { showsManualEntry = true }
                    Spacer()
                    Button("Apply to Product") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.makeCapture() == nil)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxHeight: 540)
    }

    private func reviewDimensions(_ title: String, _ dimensions: ObjectDimensions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            LabeledContent("Length", value: "\(dimensions.length.formatted(.number.precision(.fractionLength(2)))) cm")
            LabeledContent("Width", value: "\(dimensions.width.formatted(.number.precision(.fractionLength(2)))) cm")
            LabeledContent("Height", value: "\(dimensions.height.formatted(.number.precision(.fractionLength(2)))) cm")
        }
    }

    private func adjusted(_ raw: ObjectDimensions) -> ObjectDimensions {
        func value(_ measured: Double) -> Double {
            measured * (1 + state.percentageTolerance) + state.fixedToleranceCM
        }
        return ObjectDimensions(
            length: value(raw.length),
            width: value(raw.width),
            height: value(raw.height)
        )
    }

    private var qualityName: String {
        switch state.quality {
        case .good: "Good measurement quality"
        case .acceptable: "Acceptable measurement quality"
        case .low: "Low measurement quality"
        case .repeatRecommended: "Measurement should be repeated"
        }
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            "AR Measurement Unavailable",
            systemImage: "arkit",
            description: Text("This device does not support AR world tracking.")
        )
        .overlay(alignment: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }
                Button("Enter Dimensions Manually") { showsManualEntry = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func apply() {
        guard let capture = state.makeCapture() else { return }
        onConfirm(
            capture,
            state.percentageTolerance,
            state.fixedToleranceCM,
            state.canBeRotated,
            state.useAdjustedDimensions
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
