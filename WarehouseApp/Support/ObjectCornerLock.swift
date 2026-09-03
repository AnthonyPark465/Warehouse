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
    }

    var configuration = CornerEstimatorConfiguration.standard
    /// A recognised corner farther than this from the reticle is not locked.
    var maximumLockDistanceMetres = 0.08
    /// Reticle drift beyond this restarts the window (aiming at a new corner).
    var maximumReticleDriftMetres: Float = 0.10
    /// Evidence cap per recognition run. The estimators scale super-linearly
    /// with sample count; a uniform subsample keeps recognition fast while
    /// staying far above the estimators' minimum support requirements.
    var maximumEstimationSamples = 400

    private(set) var originWorld: SIMD3<Float>?
    private(set) var samples: [LocalCornerPatchSample] = []
    private var epoch = UUID()
    private var startedAt: TimeInterval?
    private var frameSequence = 0

    mutating func reset() {
        originWorld = nil
        samples.removeAll()
        epoch = UUID()
        startedAt = nil
        frameSequence = 0
    }

    /// Registers one frame's reticle hit and the depth points around it.
    /// World space is used directly: ARKit world frames are gravity-aligned,
    /// so a frame anchored at the reticle hit keeps the base surface at y = 0.
    mutating func integrate(
        reticleWorld: SIMD3<Float>,
        patchWorldPoints: [SIMD3<Float>],
        cameraWorld: SIMD3<Float>,
        timestamp: TimeInterval,
        depthConfidence: Double
    ) {
        if let originWorld,
           simd_distance(originWorld, reticleWorld) > maximumReticleDriftMetres {
            reset()
        }
        if originWorld == nil {
            originWorld = reticleWorld
            startedAt = timestamp
        }
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
                trackingState: .normal,
                depthConfidence: depthConfidence
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
        return Lock(
            worldPosition: origin + SIMD3<Float>(
                Float(corner.acceptedLocalPosition.x),
                0,
                Float(corner.acceptedLocalPosition.y)
            ),
            uncertaintyMetres: corner.uncertaintyMetres
        )
    }
}
