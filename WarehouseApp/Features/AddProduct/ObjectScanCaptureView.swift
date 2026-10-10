import RealityKit
import SwiftUI

struct ObjectScanCaptureView: View {
    let onConfirm: (ObjectScanCapture) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 46))
                    .foregroundStyle(.blue)

                Text("Choose Scan Method")
                    .font(.title2.bold())
                Text("LiDAR Fusion is the experimental low-light measurement mode. Apple Object Capture produces a more detailed photo reconstruction.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                NavigationLink {
                    LiDARFusionCaptureView(onConfirm: onConfirm)
                        .toolbar(.hidden, for: .navigationBar)
                } label: {
                    scanChoice(
                        title: "Experimental LiDAR Fusion",
                        description: "Multi-frame depth fusion · lower visible-light dependence · best for measurements",
                        symbol: "sensor.tag.radiowaves.forward"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!ObjectScannerCapabilities.hasLiDAR)

                NavigationLink {
                    AppleObjectCaptureView(onConfirm: onConfirm)
                        .toolbar(.hidden, for: .navigationBar)
                } label: {
                    scanChoice(
                        title: "Apple Object Capture",
                        description: "Guided photographs · detailed reconstruction · requires even lighting",
                        symbol: "viewfinder"
                    )
                }
                .buttonStyle(.plain)

                if !ObjectScannerCapabilities.hasLiDAR {
                    Label(
                        "Experimental LiDAR Fusion requires a LiDAR-equipped Pro device.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Scan Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func scanChoice(
        title: String,
        description: String,
        symbol: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AppleObjectCaptureView: View {
    let onConfirm: (ObjectScanCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: ObjectCaptureSession?
    @State private var state: ObjectCaptureSession.CaptureState = .initializing
    @State private var feedback: Set<ObjectCaptureSession.Feedback> = []
    @State private var captureRoot: URL?
    @State private var imagesDirectory: URL?
    @State private var checkpointDirectory: URL?
    @State private var completedPasses = 0
    @State private var countedCurrentPass = false
    @State private var shotsTaken = 0
    @State private var candidate: ObjectScanCapture?
    @State private var isReconstructing = false
    @State private var observationTask: Task<Void, Never>?
    @State private var reconstructionProgress = 0.0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if ObjectCaptureSession.isSupported, PhotogrammetrySession.isSupported {
                    if let session {
                        ObjectCaptureView(session: session)
                            .ignoresSafeArea()
                        controls(session)
                    } else {
                        ProgressView("Starting Object Capture…")
                    }
                } else {
                    ContentUnavailableView(
                        "Object Capture unavailable",
                        systemImage: "viewfinder",
                        description: Text("Apple Object Capture requires a supported LiDAR-equipped iPhone or iPad running iOS 17 or later.")
                    )
                }
            }
            .navigationTitle("Scan Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Also stops a reconstruction that is already running.
                        observationTask?.cancel()
                        session?.cancel()
                        removeCaptureFiles()
                        dismiss()
                    }
                }
            }
            .task {
                guard session == nil,
                      ObjectCaptureSession.isSupported,
                      PhotogrammetrySession.isSupported
                else { return }
                startNewSession()
            }
            .alert("Scan Problem", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func controls(_ session: ObjectCaptureSession) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Apple Object Capture", systemImage: "viewfinder")
                    Spacer()
                    Text("\(shotsTaken) photos")
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))

                Text(instruction)
                    .font(.footnote)

                if let feedbackMessage {
                    Label(feedbackMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if isReconstructing {
                    ProgressView(value: reconstructionProgress) {
                        Text("Reconstructing measurement…")
                    }
                }

                if let candidate {
                    Text(
                        "\(format(candidate.rawDimensionsCM.length)) × \(format(candidate.rawDimensionsCM.width)) × \(format(candidate.rawDimensionsCM.height)) cm"
                    )
                    .font(.headline.monospacedDigit())
                }

                actionButtons(session)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    @ViewBuilder
    private func actionButtons(_ session: ObjectCaptureSession) -> some View {
        HStack {
            switch state {
            case .ready:
                Button("Detect Object") {
                    if !session.startDetecting() {
                        errorMessage = "Object detection could not start. Keep the camera steady and try again."
                    }
                }
                .buttonStyle(.borderedProminent)

            case .detecting:
                Button("Start Capture") { session.startCapturing() }
                    .buttonStyle(.borderedProminent)
                Button("Reset Selection") { session.resetDetection() }
                    .buttonStyle(.bordered)

            case .capturing:
                if session.userCompletedScanPass {
                    Button(completedPasses >= 1 ? "Add Third Pass" : "Add Second Pass") {
                        recordCompletedPassIfNeeded()
                        session.beginNewScanPass()
                        countedCurrentPass = false
                    }
                    .buttonStyle(.bordered)

                    Button("Finish Scan") {
                        recordCompletedPassIfNeeded()
                        session.finish()
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .failed:
                Button("Try Again") { startNewSession() }
                    .buttonStyle(.borderedProminent)

            default:
                EmptyView()
            }

            if candidate != nil {
                Button("Rescan") { startNewSession() }
                    .buttonStyle(.bordered)
                Button("Confirm Scan") {
                    guard let candidate else { return }
                    onConfirm(candidate)
                    removeCaptureFiles()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var instruction: String {
        if isReconstructing {
            return "Keep this screen open while Apple reconstructs the object."
        }
        switch state {
        case .initializing:
            return "Preparing the camera…"
        case .ready:
            return "Place one object on a textured, non-reflective surface, then detect it."
        case .detecting:
            return "Adjust Apple's box so it tightly surrounds only the object."
        case .capturing:
            if session?.userCompletedScanPass == true {
                return completedPasses == 0
                    ? "First pass complete. A second pass from a different height is recommended."
                    : "Pass complete. Add another angle or finish the scan."
            }
            return "Move slowly around the object and follow Apple's capture guide."
        case .finishing, .completed:
            return "Preparing the captured photos for measurement…"
        case .failed(let error):
            return error.localizedDescription
        @unknown default:
            return "Apple Object Capture is updating the scan…"
        }
    }

    private var feedbackMessage: String? {
        if feedback.contains(.environmentTooDark) || feedback.contains(.environmentLowLight) {
            return "Add more even lighting."
        }
        if feedback.contains(.movingTooFast) {
            return "Move the phone more slowly."
        }
        if feedback.contains(.objectTooClose) {
            return "Move farther from the object."
        }
        if feedback.contains(.objectTooFar) {
            return "Move closer to the object."
        }
        if feedback.contains(.outOfFieldOfView) {
            return "Keep the entire object inside the guide."
        }
        if #available(iOS 17.4, *), feedback.contains(.objectNotDetected) {
            return "Object not detected. Add background texture or improve lighting."
        }
        return nil
    }

    @MainActor
    private func startNewSession() {
        session?.cancel()
        removeCaptureFiles()

        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WarehouseObjectCapture", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let images = root.appendingPathComponent("Images", isDirectory: true)
            let checkpoints = root.appendingPathComponent("Checkpoints", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)

            let newSession = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = checkpoints

            captureRoot = root
            imagesDirectory = images
            checkpointDirectory = checkpoints
            completedPasses = 0
            countedCurrentPass = false
            shotsTaken = 0
            candidate = nil
            reconstructionProgress = 0
            errorMessage = nil
            state = .initializing
            session = newSession
            newSession.start(imagesDirectory: images, configuration: configuration)
            observe(newSession)
        } catch {
            errorMessage = "Could not prepare Object Capture: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func observe(_ observedSession: ObjectCaptureSession) {
        observationTask?.cancel()
        observationTask = Task {
            async let stateObserver: Void = observeStates(observedSession)
            async let feedbackObserver: Void = observeFeedback(observedSession)
            async let shotObserver: Void = observeShots(observedSession)
            _ = await (stateObserver, feedbackObserver, shotObserver)
        }
    }

    @MainActor
    private func observeStates(_ observedSession: ObjectCaptureSession) async {
        for await nextState in observedSession.stateUpdates {
            guard session === observedSession else { return }
            state = nextState
            if case .capturing = nextState {
                countedCurrentPass = false
            }
            if case .failed(let error) = nextState {
                errorMessage = error.localizedDescription
            }
            if case .completed = nextState {
                await reconstructCapture(for: observedSession)
                return
            }
        }
    }

    @MainActor
    private func observeFeedback(_ observedSession: ObjectCaptureSession) async {
        for await updatedFeedback in observedSession.feedbackUpdates {
            guard session === observedSession else { return }
            feedback = updatedFeedback
        }
    }

    @MainActor
    private func observeShots(_ observedSession: ObjectCaptureSession) async {
        for await count in observedSession.numberOfShotsTakenUpdates {
            guard session === observedSession else { return }
            shotsTaken = count
        }
    }

    @MainActor
    private func reconstructCapture(for observedSession: ObjectCaptureSession) async {
        guard session === observedSession,
              !isReconstructing,
              let imagesDirectory
        else { return }

        isReconstructing = true
        defer { isReconstructing = false }

        do {
            let result = try await ObjectCaptureReconstructionService().reconstruct(
                imagesDirectory: imagesDirectory,
                checkpointDirectory: checkpointDirectory
            ) { progress in
                await MainActor.run {
                    reconstructionProgress = progress
                }
            }

            let confidence = min(
                0.98,
                0.65
                    + min(Double(shotsTaken) / 60, 1) * 0.23
                    + min(Double(max(completedPasses, 1)) / 3, 1) * 0.10
            )

            if let message = ObjectScanValidation.message(
                dimensions: result.dimensionsCM,
                confidence: confidence,
                pointCount: result.pointsInMetres.count
            ) {
                errorMessage = message
                return
            }

            candidate = ObjectScanCapture(
                id: UUID(),
                rawDimensionsCM: result.dimensionsCM,
                pointsInMetres: result.pointsInMetres,
                scanMethod: .objectCapture,
                deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                hasLiDAR: ObjectScannerCapabilities.hasLiDAR,
                confidence: confidence,
                timestamp: Date()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func recordCompletedPassIfNeeded() {
        guard !countedCurrentPass else { return }
        completedPasses += 1
        countedCurrentPass = true
    }

    private func removeCaptureFiles() {
        guard let captureRoot else { return }
        try? FileManager.default.removeItem(at: captureRoot)
        self.captureRoot = nil
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
