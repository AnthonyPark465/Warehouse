import SwiftUI

struct ManualARMeasurementView: View {
    let onConfirm: (ObjectScanCapture, Double, Double, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = ManualARMeasurementState()
    @State private var showsManualEntry = false
    #if DEBUG
    @AppStorage(LiDARScanRecordingSettings.enabledKey) private var recordsRawScans = false
    @AppStorage(LiDARScanRecordingSettings.productKey) private var recordingProduct = ""
    @AppStorage(LiDARScanRecordingSettings.stepKey) private var recordingStep = ""
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                if ObjectScannerCapabilities.isSupported {
                    ManualARSessionView(state: state).ignoresSafeArea()
                    if state.stage != .review && state.stage != .productScan {
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
            } else if state.stage == .productScan {
                productScanControls
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
        case .bottomLimit:
            Button {
                state.requestPlacement()
            } label: {
                placeButtonLabel("Set Bottom")
            }
            .disabled(!state.canPlace)
        case .topLimit:
            Button {
                state.requestPlacement()
            } label: {
                placeButtonLabel("Set Top")
            }
            .disabled(!state.canPlace)
        default:
            EmptyView()
        }
    }

    private var productScanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.productScanStatus.message)
                .font(.subheadline.weight(.semibold))
            HStack {
                Label(
                    "\(state.productScanStatus.integratedFrameCount) frames",
                    systemImage: "camera.metering.multispot"
                )
                Spacer()
                Label(
                    "\(state.productScanStatus.capturedPointCount) captured",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
            .font(.caption.monospacedDigit())
            if let dimensions = state.productScanStatus.detectedDimensionsCM {
                Text(
                    "Detected product: \(dimensions.length.formatted(.number.precision(.fractionLength(1)))) × \(dimensions.width.formatted(.number.precision(.fractionLength(1)))) × \(dimensions.height.formatted(.number.precision(.fractionLength(1)))) cm"
                )
                .font(.caption.monospacedDigit())
            }
            scanGuidance
            if state.productScanIsActive {
                Button("Finish Product Scan") { state.finishProductScan() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(!state.productScanStatus.canFinish || !state.trackingIsNormal)
            } else {
                Button("Start Product Scan") { state.startProductScan() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                #if DEBUG
                recordingControls
                #endif
            }
        }
    }

    #if DEBUG
    /// Saves the raw frames of each scan so it can be replayed off the
    /// device (`scripts/replay-measurement.sh`). Development builds only.
    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Save raw scan for validation", isOn: $recordsRawScans)
                .font(.caption)
            if recordsRawScans {
                TextField("Product name, e.g. tea-box", text: $recordingProduct)
                TextField("Test, e.g. accuracy or neighbour-10mm", text: $recordingStep)
                if let note = state.recordingNote {
                    Text(note).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
    #endif

    /// Says what evidence the scan still lacks. Failures block finishing;
    /// cautions are carried into the saved record.
    @ViewBuilder
    private var scanGuidance: some View {
        let status = state.productScanStatus
        let failureCount = status.decision.failures.count
        // The first item is already the headline message above.
        ForEach(
            Array(status.guidance.enumerated().dropFirst().prefix(2)),
            id: \.offset
        ) { index, text in
            Label(
                text,
                systemImage: index < failureCount
                    ? "exclamationmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(index < failureCount ? .yellow : .orange)
        }
        if status.decision.status == .accepted {
            Label("All scan checks passed.", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
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
                Text("AR measurements are estimates, not guaranteed dimensions. Check anything that needs precision with a tape measure.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                if let raw = state.rawDimensionsCM {
                    Text("Scanning Region")
                        .font(.headline)
                    Text("The cyan polygon and height limits only restricted where the app searched. Their size was not used as the product size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent(
                        "Boundary points",
                        value: "\(state.boundaryMarkers.count)"
                    )

                    reviewDimensions("Detected Product", raw)
                    reviewDimensions("Storage after tolerance", adjusted(raw))
                    LabeledContent(
                        "Detected surface points",
                        value: "\(state.productScanStatus.stablePointCount)"
                    )
                    LabeledContent(
                        "Scan coverage",
                        value: state.productScanStatus.confidence.formatted(
                            .percent.precision(.fractionLength(0))
                        )
                    )
                    if let uncertainty = state.productScanStatus.evidence?.uncertaintyCM {
                        LabeledContent(
                            "Estimated uncertainty",
                            value: "about ±\((uncertainty.values.max() ?? 0).formatted(.number.precision(.fractionLength(1)))) cm"
                        )
                        Text("A heuristic from scan evidence, not a calibrated or guaranteed error bound.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Scan checks", value: decisionName)
                    ForEach(
                        Array(state.productScanStatus.guidance.enumerated()),
                        id: \.offset
                    ) { _, text in
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let evidence = state.productScanStatus.evidence {
                        evidenceDetails(evidence)
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

                #if DEBUG
                if recordsRawScans, let note = state.recordingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                HStack {
                    Button("Restart", role: .destructive) { state.reset() }
                    Button("Enter Manually") { showsManualEntry = true }
                    Button("Continue Scanning") { state.continueProductScan() }
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
            LabeledContent("Length", value: "\(dimensions.length.formatted(.number.precision(.fractionLength(1)))) cm")
            LabeledContent("Width", value: "\(dimensions.width.formatted(.number.precision(.fractionLength(1)))) cm")
            LabeledContent("Height", value: "\(dimensions.height.formatted(.number.precision(.fractionLength(1)))) cm")
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

    private var decisionName: String {
        switch state.productScanStatus.decision.status {
        case .accepted: "Passed"
        case .qualified: "Passed with cautions"
        case .refused: "Not passed"
        }
    }

    private func evidenceDetails(_ evidence: LiDARMeasurementEvidence) -> some View {
        DisclosureGroup("Scan evidence") {
            LabeledContent(
                "Frames used / captured",
                value: "\(evidence.frames.acceptedFrameCountSinceReset) / \(evidence.frames.capturedFrameCount)"
            )
            LabeledContent("Repeated surface points", value: "\(evidence.voxels.stableVoxelCount)")
            if let support = evidence.supportPlane {
                LabeledContent(
                    "Supporting surface",
                    value: support.method == LiDARSupportPlaneEstimate.Method.histogramPeak.rawValue
                        ? "Detected; kept as the height base"
                        : "Not detected"
                )
            }
            if let components = evidence.components {
                LabeledContent(
                    "Gap bridging",
                    value: components.connectivityMode
                        == LiDARComponentSelection.Mode.expanded.rawValue ? "Used" : "Not needed"
                )
                LabeledContent(
                    "Other geometry excluded",
                    value: "\(components.rejectedComponentCount) piece\(components.rejectedComponentCount == 1 ? "" : "s")"
                )
            }
            if let span = evidence.coverage?.viewpointSpanDegrees {
                LabeledContent(
                    "Viewing arc",
                    value: "\(span.formatted(.number.precision(.fractionLength(0))))°"
                )
            }
            LabeledContent(
                "Region boundary",
                value: evidence.boundaryContacts.isEmpty ? "Not touched" : "Touched"
            )
        }
        .font(.caption)
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
