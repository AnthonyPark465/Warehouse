import Foundation
import simd

/// A scan saved as the pipeline received it: the locked region, the seed, and
/// every depth frame. Replaying the frames through `LiDARMeasurementSession`
/// reproduces the scan off the device, so different pipeline settings can be
/// compared on identical input (`scripts/replay-measurement.sh`).
///
/// Points whose ray never crosses the region's bounding box, widened by the
/// recorder's margin, are left out to keep files small. Fusion crops to the
/// region and free-space evidence is kept only inside it, so as long as that
/// margin covers the crop margin and the free-space grid's padding (the
/// app's does), the omitted points cannot reach a measurement. Their number
/// is stored per frame; a replay's count of samples outside the region is
/// lower than the live scan's by the omitted points of the frames that got
/// as far as being cropped.
///
/// A replay uses the pipeline as it is when replayed, not as it was when the
/// scan was recorded.
///
/// File layout (little-endian): magic `WLSC`, version, a length-prefixed JSON
/// header, then tagged records: frames, and at most one closing JSON result.
struct LiDARScanRecording {
    struct Region: Codable, Equatable {
        var kind: String
        var origin: [Float]
        var axisX: [Float]
        var axisY: [Float]
        var axisZ: [Float]
        /// Box: half extents along the three axes. Prism: empty.
        var halfExtents: [Float]
        /// Prism: polygon vertices as x, z pairs. Box: empty.
        var polygon: [[Float]]
        var lowerOffset: Float
        var upperOffset: Float

        init(_ region: LiDARSpatialRegion) {
            origin = Self.array(region.referenceOrigin)
            axisX = Self.array(region.axisX)
            axisY = Self.array(region.axisY)
            axisZ = Self.array(region.axisZ)
            switch region {
            case .box(let volume):
                kind = "box"
                halfExtents = Self.array(volume.halfExtents)
                polygon = []
                lowerOffset = 0
                upperOffset = 0
            case .polygonalPrism(let prism):
                kind = "prism"
                halfExtents = []
                polygon = prism.polygon.map { [$0.x, $0.y] }
                lowerOffset = prism.lowerOffset
                upperOffset = prism.upperOffset
            }
        }

        var spatialRegion: LiDARSpatialRegion? {
            guard origin.count == 3, axisX.count == 3, axisY.count == 3, axisZ.count == 3 else {
                return nil
            }
            switch kind {
            case "box":
                guard halfExtents.count == 3 else { return nil }
                return .box(LiDARScanVolume(
                    centre: Self.vector(origin),
                    axisX: Self.vector(axisX),
                    axisY: Self.vector(axisY),
                    axisZ: Self.vector(axisZ),
                    halfExtents: Self.vector(halfExtents)
                ))
            case "prism":
                guard polygon.count >= 3, polygon.allSatisfy({ $0.count == 2 }) else { return nil }
                return .polygonalPrism(LiDARPolygonalPrism(
                    origin: Self.vector(origin),
                    axisU: Self.vector(axisX),
                    axisV: Self.vector(axisZ),
                    normal: Self.vector(axisY),
                    polygon: polygon.map { SIMD2($0[0], $0[1]) },
                    lowerOffset: lowerOffset,
                    upperOffset: upperOffset
                ))
            default:
                return nil
            }
        }

        private static func array(_ vector: SIMD3<Float>) -> [Float] {
            [vector.x, vector.y, vector.z]
        }

        private static func vector(_ values: [Float]) -> SIMD3<Float> {
            SIMD3(values[0], values[1], values[2])
        }
    }

    struct Header: Codable, Equatable {
        /// Product name typed by the person scanning; links the file to its
        /// ground truth.
        var label: String
        /// Which test the scan belongs to, also typed by the person scanning.
        var step: String
        /// ISO 8601.
        var createdAt: String
        var deviceModel: String
        var systemVersion: String
        var region: Region
        var seed: [Float]
        /// How far beyond the region's bounding box rays were kept.
        var recorderMarginMetres: Float?
    }

    /// The pipeline's report when the scan was stopped.
    struct LiveResult: Codable, Equatable {
        var reportedDimensionsCM: ObjectDimensions?
        var decision: LiDARAcceptanceDecision
        var evidence: LiDARMeasurementEvidence
        /// What the screen showed at that moment. It can trail the report
        /// above by one frame when a frame was being processed as the scan
        /// was stopped.
        var shownDimensionsCM: ObjectDimensions?
        var shownStatus: String?
    }

    enum ReadError: Error, Equatable {
        case notARecording
        case unsupportedVersion(UInt32)
        case malformedHeader
    }

    static let fileExtension = "wlscan"
    static let currentVersion: UInt32 = 1
    fileprivate static let magic: [UInt8] = Array("WLSC".utf8)
    fileprivate static let frameTag: UInt8 = 1
    fileprivate static let resultTag: UInt8 = 2

    var header: Header
    var frames: [LiDARDepthFrame]
    /// Points left out of each frame because their ray missed the region.
    var omittedPointCounts: [Int]
    /// Nil when the file ends without a closing record (the app was closed
    /// mid-scan). The frames read up to that point are still returned.
    var liveResult: LiveResult?

    var region: LiDARSpatialRegion? { header.region.spatialRegion }

    var seed: SIMD3<Float>? {
        header.seed.count == 3 ? SIMD3(header.seed[0], header.seed[1], header.seed[2]) : nil
    }

    // MARK: Reading

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        var reader = ByteReader(data: data)
        guard let magic = reader.bytes(4), Array(magic) == Self.magic else {
            throw ReadError.notARecording
        }
        guard let version: UInt32 = reader.integer() else { throw ReadError.notARecording }
        guard version == Self.currentVersion else { throw ReadError.unsupportedVersion(version) }
        guard let headerLength: UInt32 = reader.integer(),
              let headerData = reader.bytes(Int(headerLength)),
              let header = try? JSONDecoder().decode(Header.self, from: headerData)
        else { throw ReadError.malformedHeader }
        self.header = header
        frames = []
        omittedPointCounts = []
        liveResult = nil

        // A record cut short by the app closing ends the file, not the read.
        records: while let tag: UInt8 = reader.integer() {
            switch tag {
            case Self.frameTag:
                guard let timestampBits: UInt64 = reader.integer(),
                      let tracking: UInt8 = reader.integer(),
                      let epoch: Int32 = reader.integer(),
                      let hasCamera: UInt8 = reader.integer(),
                      let camera = reader.floats(3),
                      let source: UInt8 = reader.integer(),
                      let examined: Int32 = reader.integer(),
                      let lowConfidence: Int32 = reader.integer(),
                      let outOfRange: Int32 = reader.integer(),
                      let highConfidence: Int32 = reader.integer(),
                      let omitted: Int32 = reader.integer(),
                      let pointCount: Int32 = reader.integer(),
                      pointCount >= 0,
                      let coordinates = reader.floats(Int(pointCount) * 3)
                else { break records }
                var points: [SIMD3<Float>] = []
                points.reserveCapacity(Int(pointCount))
                for index in 0..<Int(pointCount) {
                    points.append(SIMD3(
                        coordinates[index * 3],
                        coordinates[index * 3 + 1],
                        coordinates[index * 3 + 2]
                    ))
                }
                frames.append(LiDARDepthFrame(
                    points: points,
                    timestamp: Float64(bitPattern: timestampBits),
                    tracking: Self.tracking(tracking),
                    coordinateEpoch: Int(epoch),
                    cameraPosition: hasCamera == 1 ? SIMD3(camera[0], camera[1], camera[2]) : nil,
                    source: Self.source(source),
                    examinedSampleCount: Int(examined),
                    lowConfidenceSampleCount: Int(lowConfidence),
                    outOfRangeSampleCount: Int(outOfRange),
                    highConfidenceSampleCount: Int(highConfidence)
                ))
                omittedPointCounts.append(Int(omitted))
            case Self.resultTag:
                guard let length: UInt32 = reader.integer(),
                      let resultData = reader.bytes(Int(length))
                else { break records }
                liveResult = try? JSONDecoder().decode(LiveResult.self, from: resultData)
            default:
                break records
            }
        }
    }

    // MARK: Encoding helpers

    fileprivate static let trackingValues: [LiDARTrackingQuality] = [
        .normal, .limited, .relocalizing, .notAvailable
    ]
    fileprivate static let sourceValues: [LiDARDepthSource] = [
        .unspecified, .sceneDepth, .featurePoints
    ]

    private static func tracking(_ code: UInt8) -> LiDARTrackingQuality {
        Int(code) < trackingValues.count ? trackingValues[Int(code)] : .notAvailable
    }

    private static func source(_ code: UInt8) -> LiDARDepthSource {
        Int(code) < sourceValues.count ? sourceValues[Int(code)] : .unspecified
    }

    /// True when the straight line from `camera` to `point` passes through
    /// the box `lower...upper`.
    static func rayCrosses(
        lower: SIMD3<Float>,
        upper: SIMD3<Float>,
        camera: SIMD3<Float>,
        point: SIMD3<Float>
    ) -> Bool {
        let direction = point - camera
        var enter: Float = 0
        var exit: Float = 1
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if camera[axis] < lower[axis] || camera[axis] > upper[axis] { return false }
            } else {
                var near = (lower[axis] - camera[axis]) / direction[axis]
                var far = (upper[axis] - camera[axis]) / direction[axis]
                if near > far { swap(&near, &far) }
                enter = max(enter, near)
                exit = min(exit, far)
                if enter > exit { return false }
            }
        }
        return true
    }
}

/// Writes one recording as frames arrive. Not thread-safe: use it from the
/// queue that feeds the measurement session.
final class LiDARScanRecorder {
    let url: URL
    private let handle: FileHandle
    private let lower: SIMD3<Float>
    private let upper: SIMD3<Float>
    private var isOpen = true
    private(set) var frameCount = 0
    /// A write failed (most likely a full disk). The file ends at the last
    /// frame written before that and has no closing result.
    private(set) var didFail = false

    /// `margin` widens the region's bounding box when deciding which rays to
    /// keep; it must cover the crop margin and the free-space grid's padding.
    init(
        url: URL,
        header: LiDARScanRecording.Header,
        region: LiDARSpatialRegion,
        margin: Float
    ) throws {
        self.url = url
        let bounds = region.worldBounds
        lower = bounds.lower - margin
        upper = bounds.upper + margin
        var header = header
        header.recorderMarginMetres = margin
        var data = Data(LiDARScanRecording.magic)
        Self.append(LiDARScanRecording.currentVersion, to: &data)
        let headerData = try JSONEncoder().encode(header)
        Self.append(UInt32(headerData.count), to: &data)
        data.append(headerData)
        // Never replaces an existing recording.
        try data.write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        if isOpen { try? handle.close() }
    }

    func append(_ frame: LiDARDepthFrame) {
        guard isOpen else { return }
        var coordinates: [UInt32] = []
        coordinates.reserveCapacity(frame.points.count * 3)
        var omitted = 0
        for point in frame.points {
            if let camera = frame.cameraPosition,
               !LiDARScanRecording.rayCrosses(lower: lower, upper: upper, camera: camera, point: point) {
                omitted += 1
                continue
            }
            coordinates.append(point.x.bitPattern.littleEndian)
            coordinates.append(point.y.bitPattern.littleEndian)
            coordinates.append(point.z.bitPattern.littleEndian)
        }
        var data = Data()
        data.reserveCapacity(64 + coordinates.count * 4)
        data.append(LiDARScanRecording.frameTag)
        Self.append(Float64(frame.timestamp).bitPattern, to: &data)
        data.append(UInt8(LiDARScanRecording.trackingValues.firstIndex(of: frame.tracking) ?? 3))
        Self.append(Int32(truncatingIfNeeded: frame.coordinateEpoch), to: &data)
        let camera = frame.cameraPosition
        data.append(camera == nil ? 0 : 1)
        Self.append(Float32(camera?.x ?? 0).bitPattern, to: &data)
        Self.append(Float32(camera?.y ?? 0).bitPattern, to: &data)
        Self.append(Float32(camera?.z ?? 0).bitPattern, to: &data)
        data.append(UInt8(LiDARScanRecording.sourceValues.firstIndex(of: frame.source) ?? 0))
        Self.append(Int32(truncatingIfNeeded: frame.examinedSampleCount), to: &data)
        Self.append(Int32(truncatingIfNeeded: frame.lowConfidenceSampleCount), to: &data)
        Self.append(Int32(truncatingIfNeeded: frame.outOfRangeSampleCount), to: &data)
        Self.append(Int32(truncatingIfNeeded: frame.highConfidenceSampleCount), to: &data)
        Self.append(Int32(truncatingIfNeeded: omitted), to: &data)
        Self.append(Int32(coordinates.count / 3), to: &data)
        coordinates.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        if write(data) { frameCount += 1 }
    }

    /// Writes the app's own result and closes the file. Returns false when
    /// the recording is incomplete because a write failed.
    @discardableResult
    func finish(result: LiDARScanRecording.LiveResult?) -> Bool {
        guard isOpen else { return !didFail }
        if let result, let resultData = try? JSONEncoder().encode(result) {
            var data = Data([LiDARScanRecording.resultTag])
            Self.append(UInt32(resultData.count), to: &data)
            data.append(resultData)
            write(data)
        }
        if isOpen {
            try? handle.close()
            isOpen = false
        }
        return !didFail
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        guard isOpen else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            // A full disk must not interrupt the scan; the recording ends here.
            try? handle.close()
            isOpen = false
            didFail = true
            return false
        }
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, data.endIndex - offset >= count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    /// Reads a little-endian integer.
    mutating func integer<Value: FixedWidthInteger>() -> Value? {
        guard let slice = bytes(MemoryLayout<Value>.size) else { return nil }
        return Value(littleEndian: slice.withUnsafeBytes { $0.loadUnaligned(as: Value.self) })
    }

    mutating func floats(_ count: Int) -> [Float32]? {
        guard count >= 0, let slice = bytes(count * MemoryLayout<Float32>.size) else { return nil }
        return slice.withUnsafeBytes { buffer in
            (0..<count).map {
                Float32(bitPattern: UInt32(
                    littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)
                ))
            }
        }
    }
}

/// Where validation recordings go and how they are named. Recording is a
/// development aid: the switch for it is only shown in debug builds.
enum LiDARScanRecordingSettings {
    static let enabledKey = "validation.recordsRawScans"
    static let productKey = "validation.product"
    static let stepKey = "validation.step"
    /// A scan left running must not fill the phone. Past this many frames
    /// (five minutes at 10 Hz) the recording is abandoned and deleted.
    static let maximumFrameCount = 3_000

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanRecordings", isDirectory: true)
    }

    /// `product_step_yyyyMMdd-HHmmss.wlscan`, restricted to characters that
    /// are safe in a file name on every system the file may be copied to.
    ///
    /// `attempt` above zero adds a suffix, for a second scan of the same
    /// product and test within one second.
    static func fileName(product: String, step: String, date: Date, attempt: Int = 0) -> String {
        func clean(_ text: String, fallback: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let mapped = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
                allowed.contains($0) ? Character($0) : "-"
            }
            let collapsed = String(mapped)
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
            return collapsed.isEmpty ? fallback : String(collapsed.prefix(40))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return [
            clean(product, fallback: "unnamed"),
            clean(step, fallback: "scan"),
            formatter.string(from: date) + (attempt > 0 ? "-\(attempt + 1)" : "")
        ].joined(separator: "_") + "." + LiDARScanRecording.fileExtension
    }
}
