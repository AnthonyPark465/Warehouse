import Foundation
import simd

/// Rolling reticle-patch window for the product scanner.
///
/// While the user aims near an object corner, each frame's depth patch around
/// the reticle is accumulated (in a gravity-aligned frame anchored at the
/// first reticle hit) and fed to the shared corner estimators. When a corner
/// is recognised close to the aim point, a lock position is offered so the
/// marker snaps onto the real corner instead of the raw raycast.
struct ObjectCornerLockWindow {
    struct Lock: Equatable {
        let worldPosition: SIMD3<Float>
        let uncertaintyMetres: Double
        /// Frame timestamp of the recognition; placement rejects stale locks.
        let recognisedAt: TimeInterval
    }

    var configuration = CornerEstimatorConfiguration.standard
    /// A recognised corner farther than this from the reticle is not locked.
    var maximumLockDistanceMetres = 0.08
    /// Reticle drift beyond this restarts the window (aiming at a new corner).
    /// Measured against the rolling recent aim, not the first hit, so slow
    /// scanning along a long edge does not thrash the window (D3c).
    var maximumReticleDriftMetres: Float = 0.15
    /// A lock older than this at placement time is discarded (D3f).
    static let maximumLockAgeSeconds: TimeInterval = 0.4
    /// A lock farther than this from the current reticle sample is discarded
    /// at placement time (D3f). Tighter than recognition's lock distance.
    static let maximumLockToReticleMetres: Float = 0.04
    /// Evidence cap per recognition run. The estimators scale super-linearly
    /// with sample count; a uniform subsample keeps recognition fast while
    /// staying far above the estimators' minimum support requirements.
    var maximumEstimationSamples = 400

    private(set) var originWorld: SIMD3<Float>?
    private(set) var samples: [LocalCornerPatchSample] = []
    private var epoch = UUID()
    private var startedAt: TimeInterval?
    private var frameSequence = 0
    /// Exponential moving average of the reticle over roughly the last 0.5 s
    /// (integrate runs at ~10 Hz); the drift reference for `integrate`.
    private var recentReticleAverage: SIMD3<Float>?
    private let reticleSmoothing: Float = 0.25

    mutating func reset() {
        originWorld = nil
        samples.removeAll()
        epoch = UUID()
        startedAt = nil
        frameSequence = 0
        recentReticleAverage = nil
    }

    /// Placement policy: a lock may snap a placement only while fresh and
    /// near the current reticle sample; otherwise placement falls back to the
    /// raw sample. Advisory only — this can never block a placement.
    static func lockIsUsableForPlacement(
        _ lock: Lock,
        reticleWorld: SIMD3<Float>,
        at timestamp: TimeInterval
    ) -> Bool {
        timestamp - lock.recognisedAt <= maximumLockAgeSeconds
            && simd_distance(lock.worldPosition, reticleWorld)
                <= maximumLockToReticleMetres
    }

    /// Registers one frame's reticle hit and the depth points around it.
    /// World space is used directly: ARKit world frames are gravity-aligned,
    /// so a frame anchored at the reticle hit keeps the base surface at y = 0.
    mutating func integrate(
        reticleWorld: SIMD3<Float>,
        patchWorldPoints: [SIMD3<Float>],
        cameraWorld: SIMD3<Float>,
        timestamp: TimeInterval,
        depthConfidence: Double,
        trackingState: TrackingQualitySnapshot = .normal
    ) {
        if let recent = recentReticleAverage,
           simd_distance(recent, reticleWorld) > maximumReticleDriftMetres {
            reset()
        }
        if originWorld == nil {
            originWorld = reticleWorld
            startedAt = timestamp
        }
        recentReticleAverage = recentReticleAverage.map {
            $0 + (reticleWorld - $0) * reticleSmoothing
        } ?? reticleWorld
        guard let origin = originWorld else { return }
        frameSequence += 1
        let cameraLocal = cameraWorld - origin
        for point in patchWorldPoints {
            let local = point - origin
            samples.append(LocalCornerPatchSample(
                id: UUID(),
                localPosition: Vector3D(
                    Double(local.x),
                    Double(local.y),
                    Double(local.z)
                ),
                cameraPositionLocal: Vector3D(
                    Double(cameraLocal.x),
                    Double(cameraLocal.y),
                    Double(cameraLocal.z)
                ),
                timestamp: timestamp,
                frameSequence: frameSequence,
                trackingState: trackingState,
                depthConfidence: depthConfidence,
                coordinateEpoch: epoch
            ))
        }
        // Slide the window so stale geometry cannot outvote fresh evidence.
        let cutoff = timestamp - configuration.maximumCaptureDurationSeconds
        if let oldest = samples.first?.timestamp, oldest < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
            startedAt = samples.first?.timestamp ?? timestamp
        }
    }

    /// Attempts recognition; nil until a confident corner sits near the reticle.
    func recognisedCorner(
        reticleWorld: SIMD3<Float>,
        at timestamp: TimeInterval
    ) -> Lock? {
        guard let origin = originWorld,
              let startedAt,
              timestamp - startedAt >= configuration.minimumCaptureDurationSeconds,
              !samples.isEmpty
        else { return nil }

        let reticleLocal = reticleWorld - origin
        let evidence: [LocalCornerPatchSample]
        if samples.count > maximumEstimationSamples {
            let stride = Swift.max(2, samples.count / maximumEstimationSamples)
            evidence = samples.enumerated().compactMap { index, sample in
                index.isMultiple(of: stride) ? sample : nil
            }
        } else {
            evidence = samples
        }
        let capture = CornerPatchCapture(
            samples: evidence,
            reticleLocalPosition: Vector2D(
                Double(reticleLocal.x),
                Double(reticleLocal.z)
            ),
            coordinateEpoch: epoch,
            startedAt: startedAt,
            endedAt: timestamp
        )
        guard case .success(let corner) = DefaultLocalCornerEstimator.estimate(
            capture: capture,
            configuration: configuration
        ) else { return nil }

        let offset = SIMD2<Double>(
            corner.acceptedLocalPosition.x - Double(reticleLocal.x),
            corner.acceptedLocalPosition.y - Double(reticleLocal.z)
        )
        guard simd_length(offset) <= maximumLockDistanceMetres else { return nil }
        // The estimators solve in the horizontal plane; the corner's height is
        // the median elevation of the captured patch (the surface the fit was
        // anchored to), not the window origin's y = 0 (D3e).
        let elevation = medianValue(evidence.map(\.localPosition.y))
        return Lock(
            worldPosition: origin + SIMD3<Float>(
                Float(corner.acceptedLocalPosition.x),
                elevation.isFinite ? Float(elevation) : 0,
                Float(corner.acceptedLocalPosition.y)
            ),
            uncertaintyMetres: corner.uncertaintyMetres,
            recognisedAt: timestamp
        )
    }

    private func medianValue(_ values: [Double]) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return .infinity }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
