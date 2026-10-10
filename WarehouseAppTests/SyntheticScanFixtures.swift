import Foundation
import simd
#if canImport(WarehouseApp)
@testable import WarehouseApp
#endif

// SYNTHETIC DATA ONLY. Everything in this file is generated geometry with a
// simple noise model. It exercises the pipeline's logic; it says nothing
// about accuracy on a physical iPhone.
//
// Simplifications relative to a real LiDAR scan:
// - A surface point is visible when its outward normal faces the camera.
//   By default one object never occludes another, and nothing casts a
//   shadow. `SyntheticScanPlan.modelsOcclusion` adds ray-object occlusion,
//   which anything that reasons about rays (free-space evidence) needs.
// - Noise is Gaussian along the viewing ray, independent per sample. Real
//   depth error is correlated, grows at edges, and depends on material.
// - Camera poses are exact; there is no tracking drift.

/// SplitMix64: small, fast, and the same integer stream on every run.
/// Values derived through floating-point `log`/`cos` may differ in the last
/// bit between toolchains.
struct SyntheticRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func uniform(_ range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// Standard normal by Box–Muller.
    mutating func gaussian() -> Float {
        let u = max(uniform(), 1e-7)
        let v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

struct SyntheticSurfacePoint {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct SyntheticObject {
    enum Shape {
        /// `size` is x, height, z before yaw.
        case box(size: SIMD3<Float>)
        case cylinder(radius: Float, height: Float)
    }

    var shape: Shape
    /// Centre of the base, resting on the support.
    var baseCentre: SIMD3<Float>
    var yaw: Float = 0
    /// Distance between surface samples.
    var spacing: Float = 0.0025
    /// Keeps only this share of surface samples, chosen once per object, so
    /// the same holes persist in every frame.
    var retainedFraction: Float = 1
    /// Faces to omit entirely, e.g. a face pressed against a wall.
    var omittedNormals: [SIMD3<Float>] = []
    /// Boxes only: keeps square tiles of surface `tile` wide separated by
    /// unscanned strips `strip` wide, on every face. Models a surface that
    /// returns depth only in patches (dark or glossy bands). The solid still
    /// occludes.
    var patches: (tile: Float, strip: Float)?

    /// True length, width (length ≥ width) and height in centimetres.
    var trueDimensionsCM: ObjectDimensions {
        switch shape {
        case .box(let size):
            ObjectDimensions(
                length: Double(max(size.x, size.z)) * 100,
                width: Double(min(size.x, size.z)) * 100,
                height: Double(size.y) * 100
            )
        case .cylinder(let radius, let height):
            ObjectDimensions(
                length: Double(radius) * 200,
                width: Double(radius) * 200,
                height: Double(height) * 100
            )
        }
    }

    /// Half extents of the footprint before yaw, for occlusion of the support.
    var footprintHalfExtents: SIMD2<Float> {
        switch shape {
        case .box(let size): SIMD2(size.x / 2, size.z / 2)
        case .cylinder(let radius, _): SIMD2(radius, radius)
        }
    }

    func rotate(_ local: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            cos(yaw) * local.x + sin(yaw) * local.z,
            local.y,
            -sin(yaw) * local.x + cos(yaw) * local.z
        )
    }

    func covers(_ point: SIMD3<Float>) -> Bool {
        let offset = point - baseCentre
        let local = SIMD3<Float>(
            cos(yaw) * offset.x - sin(yaw) * offset.z,
            offset.y,
            sin(yaw) * offset.x + cos(yaw) * offset.z
        )
        switch shape {
        case .box:
            return abs(local.x) <= footprintHalfExtents.x
                && abs(local.z) <= footprintHalfExtents.y
        case .cylinder(let radius, _):
            return simd_length(SIMD2(local.x, local.z)) <= radius
        }
    }

    /// True when the point lies inside the solid grown by `margin`.
    func contains(_ point: SIMD3<Float>, margin: Float) -> Bool {
        let offset = point - baseCentre
        let local = SIMD3<Float>(
            cos(yaw) * offset.x - sin(yaw) * offset.z,
            offset.y,
            sin(yaw) * offset.x + cos(yaw) * offset.z
        )
        switch shape {
        case .box(let size):
            return abs(local.x) <= size.x / 2 + margin
                && abs(local.z) <= size.z / 2 + margin
                && local.y >= -margin && local.y <= size.y + margin
        case .cylinder(let radius, let height):
            return simd_length(SIMD2(local.x, local.z)) <= radius + margin
                && local.y >= -margin && local.y <= height + margin
        }
    }

    /// True when the straight line from `origin` to `target` passes through
    /// the solid before reaching `target`. A target on the surface facing
    /// the origin is not blocked by its own object.
    func blocks(from origin: SIMD3<Float>, to target: SIMD3<Float>) -> Bool {
        func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let offset = point - baseCentre
            return SIMD3<Float>(
                cos(yaw) * offset.x - sin(yaw) * offset.z,
                offset.y,
                sin(yaw) * offset.x + cos(yaw) * offset.z
            )
        }
        let start = local(origin)
        let direction = local(target) - start
        // Parameter range of the segment inside the solid.
        var enter: Float = 0
        var exit: Float = 1
        func clip(_ position: Float, _ step: Float, _ low: Float, _ high: Float) -> Bool {
            if abs(step) < 1e-9 { return position > low && position < high }
            var near = (low - position) / step
            var far = (high - position) / step
            if near > far { swap(&near, &far) }
            enter = max(enter, near)
            exit = min(exit, far)
            return enter < exit
        }
        // Shrunk slightly so a ray along a face does not count as inside.
        let inset: Float = 1e-5
        switch shape {
        case .box(let size):
            guard clip(start.x, direction.x, -size.x / 2 + inset, size.x / 2 - inset),
                  clip(start.y, direction.y, inset, size.y - inset),
                  clip(start.z, direction.z, -size.z / 2 + inset, size.z / 2 - inset)
            else { return false }
        case .cylinder(let radius, let height):
            guard clip(start.y, direction.y, inset, height - inset) else { return false }
            let reach = radius - inset
            let a = direction.x * direction.x + direction.z * direction.z
            let b = 2 * (start.x * direction.x + start.z * direction.z)
            let c = start.x * start.x + start.z * start.z - reach * reach
            if a < 1e-12 {
                guard c < 0 else { return false }
            } else {
                let discriminant = b * b - 4 * a * c
                guard discriminant > 0 else { return false }
                let root = discriminant.squareRoot()
                enter = max(enter, (-b - root) / (2 * a))
                exit = min(exit, (-b + root) / (2 * a))
                guard enter < exit else { return false }
            }
        }
        // Entering only at the far end is the target's own surface.
        return enter < 1 - 1e-4
    }

    private func isInsidePatch(_ local: SIMD3<Float>, _ normal: SIMD3<Float>) -> Bool {
        guard let patches else { return true }
        let period = patches.tile + patches.strip
        func isOnTile(_ value: Float) -> Bool {
            value - (value / period).rounded(.down) * period < patches.tile
        }
        if abs(normal.y) > 0.5 { return isOnTile(local.x) && isOnTile(local.z) }
        return isOnTile(local.y) && isOnTile(abs(normal.x) > 0.5 ? local.z : local.x)
    }

    func surfacePoints(random: inout SyntheticRandom) -> [SyntheticSurfacePoint] {
        var points: [SyntheticSurfacePoint] = []
        func append(_ local: SIMD3<Float>, _ normal: SIMD3<Float>) {
            if omittedNormals.contains(where: { simd_dot($0, normal) > 0.99 }) { return }
            if !isInsidePatch(local, normal) { return }
            points.append(SyntheticSurfacePoint(
                position: rotate(local) + baseCentre,
                normal: rotate(normal)
            ))
        }
        func steps(_ length: Float) -> Int { max(Int((length / spacing).rounded()), 1) }

        switch shape {
        case .box(let size):
            let xSteps = steps(size.x)
            let ySteps = steps(size.y)
            let zSteps = steps(size.z)
            for xIndex in 0...xSteps {
                let x = -size.x / 2 + size.x * Float(xIndex) / Float(xSteps)
                for yIndex in 0...ySteps {
                    let y = size.y * Float(yIndex) / Float(ySteps)
                    append(SIMD3(x, y, -size.z / 2), SIMD3(0, 0, -1))
                    append(SIMD3(x, y, size.z / 2), SIMD3(0, 0, 1))
                }
                for zIndex in 0...zSteps {
                    let z = -size.z / 2 + size.z * Float(zIndex) / Float(zSteps)
                    append(SIMD3(x, size.y, z), SIMD3(0, 1, 0))
                }
            }
            for zIndex in 0...zSteps {
                let z = -size.z / 2 + size.z * Float(zIndex) / Float(zSteps)
                for yIndex in 0...ySteps {
                    let y = size.y * Float(yIndex) / Float(ySteps)
                    append(SIMD3(-size.x / 2, y, z), SIMD3(-1, 0, 0))
                    append(SIMD3(size.x / 2, y, z), SIMD3(1, 0, 0))
                }
            }
        case .cylinder(let radius, let height):
            let angleCount = max(Int((2 * .pi * radius / spacing).rounded()), 12)
            let ySteps = steps(height)
            for yIndex in 0...ySteps {
                let y = height * Float(yIndex) / Float(ySteps)
                for angleIndex in 0..<angleCount {
                    let angle = Float(angleIndex) * 2 * .pi / Float(angleCount)
                    let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
                    append(direction * radius + SIMD3(0, y, 0), direction)
                }
            }
            let radialSteps = steps(radius)
            for radialIndex in 0...radialSteps {
                let ring = radius * Float(radialIndex) / Float(radialSteps)
                let ringCount = max(Int((2 * .pi * ring / spacing).rounded()), 1)
                for angleIndex in 0..<ringCount {
                    let angle = Float(angleIndex) * 2 * .pi / Float(ringCount)
                    append(SIMD3(cos(angle) * ring, height, sin(angle) * ring), SIMD3(0, 1, 0))
                }
            }
        }
        guard retainedFraction < 1 else { return points }
        return points.filter { _ in random.uniform() < retainedFraction }
    }
}

struct SyntheticScene {
    /// The first object is the one the scan is meant to measure.
    var objects: [SyntheticObject]
    /// Half-width of the square support patch; nil for no visible support.
    var supportHalfExtent: Float? = 0.14
    var supportSpacing: Float = 0.004
    var supportHeight: Float = 0
    /// Extra Gaussian height noise on support samples only.
    var supportNoiseSigma: Float = 0

    var target: SyntheticObject { objects[0] }

    func surfacePoints(random: inout SyntheticRandom) -> (
        objects: [SyntheticSurfacePoint],
        support: [SyntheticSurfacePoint]
    ) {
        var objectPoints: [SyntheticSurfacePoint] = []
        for object in objects {
            var lifted = object
            lifted.baseCentre.y += supportHeight
            objectPoints += lifted.surfacePoints(random: &random)
        }
        var support: [SyntheticSurfacePoint] = []
        if let supportHalfExtent {
            let steps = Int(supportHalfExtent / supportSpacing)
            for xIndex in -steps...steps {
                for zIndex in -steps...steps {
                    let point = SIMD3<Float>(
                        Float(xIndex) * supportSpacing,
                        supportHeight,
                        Float(zIndex) * supportSpacing
                    )
                    // The support under an object is hidden by it.
                    if objects.contains(where: { $0.covers(point) }) { continue }
                    support.append(SyntheticSurfacePoint(position: point, normal: SIMD3(0, 1, 0)))
                }
            }
        }
        return (objectPoints, support)
    }
}

struct SyntheticScanPlan {
    var frameCount = 40
    /// Camera azimuth around the target, measured in the horizontal plane.
    var startAzimuthDegrees: Float = 20
    var sweepDegrees: Float = 300
    var cameraDistance: Float = 0.40
    var cameraHeight: Float = 0.35
    /// Standard deviation of depth noise along the viewing ray.
    var depthNoiseSigma: Float = 0
    /// Share of visible samples randomly missing from each frame.
    var dropoutFraction: Float = 0
    var frameInterval: TimeInterval = 0.1
    var seed: UInt64 = 1
    /// Report camera positions, so viewpoint coverage can be assessed.
    var reportsCameraPosition = true
    /// Hide surface points that another part of the scene stands in front
    /// of. Off by default so earlier fixtures keep their exact point sets.
    var modelsOcclusion = false
}

enum SyntheticScanner {
    static func cameraPosition(
        frame index: Int,
        plan: SyntheticScanPlan,
        around centre: SIMD3<Float>
    ) -> SIMD3<Float> {
        let fraction = plan.frameCount > 1
            ? Float(index) / Float(plan.frameCount - 1)
            : 0
        let azimuth = (plan.startAzimuthDegrees + plan.sweepDegrees * fraction) * .pi / 180
        return centre + SIMD3<Float>(
            cos(azimuth) * plan.cameraDistance,
            plan.cameraHeight,
            sin(azimuth) * plan.cameraDistance
        )
    }

    /// Registered frames for an orbit around the scene's target.
    static func frames(scene: SyntheticScene, plan: SyntheticScanPlan) -> [LiDARDepthFrame] {
        var random = SyntheticRandom(seed: plan.seed)
        let surfaces = scene.surfacePoints(random: &random)
        let centre = scene.target.baseCentre + SIMD3<Float>(0, scene.supportHeight, 0)
        let occluders: [SyntheticObject] = plan.modelsOcclusion
            ? scene.objects.map {
                var lifted = $0
                lifted.baseCentre.y += scene.supportHeight
                return lifted
            }
            : []
        var frames: [LiDARDepthFrame] = []
        frames.reserveCapacity(plan.frameCount)
        for index in 0..<plan.frameCount {
            let camera = cameraPosition(frame: index, plan: plan, around: centre)
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(surfaces.objects.count + surfaces.support.count)
            func observe(_ surface: SyntheticSurfacePoint, extraHeightSigma: Float) {
                let toCamera = camera - surface.position
                guard simd_dot(surface.normal, toCamera) > 0 else { return }
                if occluders.contains(where: { $0.blocks(from: camera, to: surface.position) }) {
                    return
                }
                if plan.dropoutFraction > 0, random.uniform() < plan.dropoutFraction { return }
                var position = surface.position
                if plan.depthNoiseSigma > 0 {
                    position += simd_normalize(toCamera) * (random.gaussian() * plan.depthNoiseSigma)
                }
                if extraHeightSigma > 0 {
                    position.y += random.gaussian() * extraHeightSigma
                }
                points.append(position)
            }
            for surface in surfaces.objects { observe(surface, extraHeightSigma: 0) }
            for surface in surfaces.support {
                observe(surface, extraHeightSigma: scene.supportNoiseSigma)
            }
            frames.append(LiDARDepthFrame(
                points: points,
                timestamp: Double(index + 1) * plan.frameInterval,
                cameraPosition: plan.reportsCameraPosition ? camera : nil
            ))
        }
        return frames
    }
}

enum SyntheticRegions {
    /// Square prism centred on the origin, like a region marked by hand.
    static func prism(
        halfWidth: Float = 0.12,
        lowerOffset: Float = -0.01,
        upperOffset: Float = 0.15,
        centre: SIMD2<Float> = .zero
    ) -> LiDARSpatialRegion {
        .polygonalPrism(LiDARPolygonalPrism(
            origin: SIMD3<Float>(centre.x, 0, centre.y),
            axisU: SIMD3<Float>(1, 0, 0),
            axisV: SIMD3<Float>(0, 0, 1),
            normal: SIMD3<Float>(0, 1, 0),
            polygon: [
                SIMD2<Float>(-halfWidth, -halfWidth),
                SIMD2<Float>(halfWidth, -halfWidth),
                SIMD2<Float>(halfWidth, halfWidth),
                SIMD2<Float>(-halfWidth, halfWidth)
            ],
            lowerOffset: lowerOffset,
            upperOffset: upperOffset
        ))
    }

    /// The seed the app derives for a region: its middle, 2 cm above the
    /// lower limit.
    static func seed(centre: SIMD2<Float> = .zero, lowerOffset: Float = -0.01) -> SIMD3<Float> {
        SIMD3<Float>(centre.x, lowerOffset + 0.02, centre.y)
    }
}

extension LiDARMeasurementSession {
    /// Runs a whole synthetic scan and returns the final report.
    @discardableResult
    func run(
        _ frames: [LiDARDepthFrame],
        region: LiDARSpatialRegion,
        seed: SIMD3<Float>
    ) -> LiDARMeasurementReport {
        begin(region: region, seed: seed)
        for frame in frames { process(frame) }
        return refresh()
    }
}

/// Point sets built directly on the voxel grid, for cases whose exact voxel
/// layout matters (connectivity, expiry, support selection).
enum SyntheticVoxelShapes {
    static let voxelSize: Float = 0.003

    static func centre(_ x: Int32, _ y: Int32, _ z: Int32) -> SIMD3<Float> {
        (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * voxelSize
    }

    /// Sides and top of a box given in voxel indices. `step` 2 keeps every
    /// other voxel, leaving an empty voxel between neighbours.
    static func shell(
        minimum: SIMD3<Int32>,
        maximum: SIMD3<Int32>,
        step: Int32 = 1,
        includesTop: Bool = true,
        omitting omitted: (SIMD3<Int32>) -> Bool = { _ in false }
    ) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for x in stride(from: minimum.x, through: maximum.x, by: Int(step)) {
            for y in stride(from: minimum.y, through: maximum.y, by: Int(step)) {
                for z in stride(from: minimum.z, through: maximum.z, by: Int(step)) {
                    let onSide = x == minimum.x || x == maximum.x
                        || z == minimum.z || z == maximum.z
                    guard onSide || (includesTop && y == maximum.y) else { continue }
                    if omitted(SIMD3(x, y, z)) { continue }
                    points.append(centre(x, y, z))
                }
            }
        }
        return points
    }

    /// Horizontal square of samples at one height.
    static func plane(
        halfExtent: Float = 0.11,
        height: Float = 0,
        spacing: Float = 0.004,
        centre: SIMD2<Float> = .zero
    ) -> [SIMD3<Float>] {
        let steps = Int(halfExtent / spacing)
        return (-steps...steps).flatMap { xIndex in
            (-steps...steps).map { zIndex in
                SIMD3<Float>(
                    centre.x + Float(xIndex) * spacing,
                    height,
                    centre.y + Float(zIndex) * spacing
                )
            }
        }
    }

    /// The same points in every frame, seen from an orbiting camera.
    static func repeatedOrbit(
        _ points: [SIMD3<Float>],
        count: Int = 24,
        plan: SyntheticScanPlan = SyntheticScanPlan(frameCount: 24)
    ) -> [LiDARDepthFrame] {
        (0..<count).map { index in
            LiDARDepthFrame(
                points: points,
                timestamp: Double(index + 1) * plan.frameInterval,
                cameraPosition: SyntheticScanner.cameraPosition(
                    frame: index % max(plan.frameCount, 1),
                    plan: plan,
                    around: .zero
                )
            )
        }
    }
}
