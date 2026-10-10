import Foundation
import RealityKit

struct ObjectCaptureReconstructionResult {
    let dimensionsCM: ObjectDimensions
    let pointsInMetres: [SIMD3<Float>]
}

enum ObjectCaptureDimensionExtractor {
    /// Object Capture uses Y as the gravity-aligned vertical axis. Treat the
    /// longer horizontal side as length so rotating the item on the table
    /// does not swap warehouse length and width.
    static func dimensionsCM(extentsInMetres extents: SIMD3<Float>) -> ObjectDimensions {
        let horizontal = [Double(abs(extents.x)), Double(abs(extents.z))].sorted(by: >)
        return ObjectDimensions(
            length: horizontal[0] * 100,
            width: horizontal[1] * 100,
            height: Double(abs(extents.y)) * 100
        )
    }
}

enum ObjectCaptureReconstructionError: LocalizedError {
    case missingBounds
    case processingCancelled
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBounds:
            "Apple Object Capture could not determine the object's bounds. Capture another pass with better lighting and more background texture."
        case .processingCancelled:
            "Object reconstruction was cancelled."
        case .requestFailed(let message):
            "Object reconstruction failed: \(message)"
        }
    }
}

final class ObjectCaptureReconstructionService {
    private let maximumPreviewPoints = 4_000

    func reconstruct(
        imagesDirectory: URL,
        checkpointDirectory: URL?,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ObjectCaptureReconstructionResult {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = true

        let session = try PhotogrammetrySession(
            input: imagesDirectory,
            configuration: configuration
        )
        try session.process(requests: [.bounds, .pointCloud])

        // Reconstruction is the most expensive work in the app. Stop it as
        // soon as the caller's task is cancelled instead of running to the end.
        return try await withTaskCancellationHandler {
            try await collect(from: session, onProgress: onProgress)
        } onCancel: {
            session.cancel()
        }
    }

    private func collect(
        from session: PhotogrammetrySession,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ObjectCaptureReconstructionResult {
        var bounds: BoundingBox?
        var points: [SIMD3<Float>] = []

        for try await output in session.outputs {
            switch output {
            case .requestComplete(.bounds, .bounds(let result)):
                bounds = result
            case .requestComplete(.pointCloud, .pointCloud(let cloud)):
                points = downsample(cloud.points.map(\.position))
            case .requestProgress(_, let fractionComplete):
                await onProgress(fractionComplete)
            case .requestError(_, let error):
                throw ObjectCaptureReconstructionError.requestFailed(error.localizedDescription)
            case .processingCancelled:
                throw ObjectCaptureReconstructionError.processingCancelled
            case .processingComplete:
                guard let bounds else {
                    throw ObjectCaptureReconstructionError.missingBounds
                }
                let centredPoints = points.map { $0 - bounds.center }
                return ObjectCaptureReconstructionResult(
                    dimensionsCM: ObjectCaptureDimensionExtractor.dimensionsCM(
                        extentsInMetres: bounds.extents
                    ),
                    pointsInMetres: centredPoints
                )
            default:
                break
            }
        }

        throw ObjectCaptureReconstructionError.missingBounds
    }

    private func downsample(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > maximumPreviewPoints else { return points }
        let stride = max(points.count / maximumPreviewPoints, 1)
        return Swift.stride(from: 0, to: points.count, by: stride)
            .prefix(maximumPreviewPoints)
            .map { points[$0] }
    }
}
