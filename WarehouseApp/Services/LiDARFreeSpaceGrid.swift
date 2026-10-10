import Foundation
import simd

/// Free-space evidence for the locked region.
///
/// A depth return says where a surface is. It also says the space between
/// the camera and that surface is empty. This grid keeps the second fact:
/// for each voxel of the region's bounding box, the number of distinct frames
/// in which a ray passed through the voxel on its way to a farther return.
///
/// A voxel with no return and no ray through it was simply not observed. A
/// voxel that rays passed through was observed to be empty. Component
/// selection uses the difference to decide whether a gap may be bridged.
///
/// Cells are aligned with `LiDARVoxelKey`, so a key addresses the same volume
/// here as in fusion.
struct LiDARFreeSpaceGrid {
    private let cellSize: Float
    private let originKey: SIMD3<Int32>
    private let dimensions: SIMD3<Int32>
    private let lowerBound: SIMD3<Float>
    private let upperBound: SIMD3<Float>
    private var frameCounts: [UInt16]
    /// Last frame that marked each cell, so a frame counts once per cell.
    private var lastFrame: [UInt32]

    /// Rays that crossed the grid.
    private(set) var rayCount = 0
    /// Cells seen through in at least one frame.
    private(set) var observedVoxelCount = 0

    /// Nil when the region is degenerate or needs more than `maximumCellCount` cells.
    init?(
        region: LiDARSpatialRegion,
        cellSize: Float,
        margin: Float,
        maximumCellCount: Int
    ) {
        guard cellSize.isFinite, cellSize > 0, margin.isFinite else { return nil }
        let bounds = region.worldBounds
        // Keys must be representable before any conversion to an integer.
        let limit = Float(Int32.max / 2) * cellSize
        for axis in 0..<3 {
            guard bounds.lower[axis].isFinite, bounds.upper[axis].isFinite,
                  bounds.lower[axis] <= bounds.upper[axis],
                  abs(bounds.lower[axis]) < limit, abs(bounds.upper[axis]) < limit
            else { return nil }
        }
        let low = LiDARVoxelKey.containing(bounds.lower - margin, cellSize: cellSize)
        let high = LiDARVoxelKey.containing(bounds.upper + margin, cellSize: cellSize)
        let size = SIMD3<Int64>(
            Int64(high.x) - Int64(low.x) + 1,
            Int64(high.y) - Int64(low.y) + 1,
            Int64(high.z) - Int64(low.z) + 1
        )
        guard size.x > 0, size.y > 0, size.z > 0,
              size.x <= Int64(maximumCellCount),
              size.y <= Int64(maximumCellCount),
              size.z <= Int64(maximumCellCount),
              size.x * size.y <= Int64(maximumCellCount),
              size.x * size.y * size.z <= Int64(maximumCellCount)
        else { return nil }
        self.cellSize = cellSize
        originKey = SIMD3(low.x, low.y, low.z)
        dimensions = SIMD3(Int32(size.x), Int32(size.y), Int32(size.z))
        lowerBound = SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z)) * cellSize
        upperBound = lowerBound
            + SIMD3<Float>(Float(size.x), Float(size.y), Float(size.z)) * cellSize
        let count = Int(size.x * size.y * size.z)
        frameCounts = [UInt16](repeating: 0, count: count)
        lastFrame = [UInt32](repeating: 0, count: count)
    }

    mutating func removeAll() {
        for index in frameCounts.indices {
            frameCounts[index] = 0
            lastFrame[index] = 0
        }
        rayCount = 0
        observedVoxelCount = 0
    }

    /// Frames in which a ray passed through the voxel; 0 outside the grid.
    func frameCount(at key: LiDARVoxelKey) -> Int {
        let x = key.x &- originKey.x
        let y = key.y &- originKey.y
        let z = key.z &- originKey.z
        guard x >= 0, y >= 0, z >= 0,
              x < dimensions.x, y < dimensions.y, z < dimensions.z
        else { return 0 }
        return Int(frameCounts[(Int(x) * Int(dimensions.y) + Int(y)) * Int(dimensions.z) + Int(z)])
    }

    /// Marks every cell crossed by the rays from `camera` to each point,
    /// stopping `stopShort` before the point. `frame` must be non-zero and
    /// differ between frames.
    mutating func integrate(
        camera: SIMD3<Float>,
        points: [SIMD3<Float>],
        stopShort: Float,
        frame: UInt32
    ) {
        guard camera.x.isFinite, camera.y.isFinite, camera.z.isFinite else { return }
        let cell = cellSize
        let low = lowerBound
        let high = upperBound
        let size = dimensions
        let strideX = Int(size.y) * Int(size.z)
        let strideY = Int(size.z)
        var rays = 0
        var newlyObserved = 0
        frameCounts.withUnsafeMutableBufferPointer { counts in
            lastFrame.withUnsafeMutableBufferPointer { stamps in
                for point in points {
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
                    let offset = point - camera
                    let length = simd_length(offset)
                    guard length > stopShort, length > 0 else { continue }
                    let direction = offset / length

                    // Clip the ray to the grid (slab test).
                    var enter: Float = 0
                    var exit = length - stopShort
                    var misses = false
                    for axis in 0..<3 {
                        if abs(direction[axis]) < 1e-9 {
                            if camera[axis] < low[axis] || camera[axis] >= high[axis] {
                                misses = true
                                break
                            }
                        } else {
                            var near = (low[axis] - camera[axis]) / direction[axis]
                            var far = (high[axis] - camera[axis]) / direction[axis]
                            if near > far { swap(&near, &far) }
                            enter = max(enter, near)
                            exit = min(exit, far)
                            if enter >= exit {
                                misses = true
                                break
                            }
                        }
                    }
                    if misses { continue }
                    rays += 1

                    // Voxel traversal (Amanatides–Woo), in scalars: this
                    // loop runs about a million times per frame.
                    //
                    // A ray entering through a face starts a hair inside it,
                    // so the first cell is the one being entered. A ray that
                    // starts inside the grid starts exactly where it is.
                    let nudge = enter > 0 ? min(cell * 1e-3, (exit - enter) / 2) : 0
                    let start = camera + direction * (enter + nudge)
                    let origin = originKey
                    func setUp(_ axis: Int) -> (index: Int, step: Int, next: Float, delta: Float) {
                        // The same quantization as `LiDARVoxelKey.containing`,
                        // so a cell here is the voxel fusion would address.
                        let key = Int((start[axis] / cell).rounded(.down))
                        let index = min(max(key - Int(origin[axis]), 0), Int(size[axis]) - 1)
                        let cellKey = index + Int(origin[axis])
                        if direction[axis] > 1e-9 {
                            let boundary = Float(cellKey + 1) * cell
                            return (
                                index, 1,
                                (boundary - camera[axis]) / direction[axis],
                                cell / direction[axis]
                            )
                        }
                        if direction[axis] < -1e-9 {
                            let boundary = Float(cellKey) * cell
                            return (
                                index, -1,
                                (boundary - camera[axis]) / direction[axis],
                                -cell / direction[axis]
                            )
                        }
                        return (index, 0, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
                    }
                    var (x, stepX, nextX, deltaX) = setUp(0)
                    var (y, stepY, nextY, deltaY) = setUp(1)
                    var (z, stepZ, nextZ, deltaZ) = setUp(2)
                    let sizeX = Int(size.x)
                    let sizeY = Int(size.y)
                    let sizeZ = Int(size.z)
                    while true {
                        let flat = x * strideX + y * strideY + z
                        if stamps[flat] != frame {
                            stamps[flat] = frame
                            if counts[flat] == 0 { newlyObserved += 1 }
                            if counts[flat] < .max { counts[flat] += 1 }
                        }
                        // Axes that reach a boundary at the same moment step
                        // together: a ray through an edge or corner enters
                        // the cell diagonally opposite and only touches the
                        // ones beside it.
                        let crossing = min(nextX, min(nextY, nextZ))
                        guard crossing < exit else { break }
                        if nextX == crossing {
                            x += stepX
                            nextX += deltaX
                        }
                        if nextY == crossing {
                            y += stepY
                            nextY += deltaY
                        }
                        if nextZ == crossing {
                            z += stepZ
                            nextZ += deltaZ
                        }
                        guard x >= 0, x < sizeX, y >= 0, y < sizeY, z >= 0, z < sizeZ else { break }
                    }
                }
            }
        }
        rayCount += rays
        observedVoxelCount += newlyObserved
    }
}
