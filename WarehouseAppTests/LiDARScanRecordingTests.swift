import XCTest
import simd
@testable import WarehouseApp

/// The recording format and the replay path built on it. The scans here are
/// SYNTHETIC; the tests check that a recording reproduces the scan it was
/// made from, not anything about device accuracy.
final class LiDARScanRecordingTests: XCTestCase {
    private var folder: URL!
    private let configuration = LiDARFusionConfiguration.smallObject

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRecordingRoundTripsHeaderFramesAndResult() throws {
        let region = SyntheticRegions.prism()
        var frames = boxFrames(count: 3)
        frames[1].tracking = .limited
        frames[1].coordinateEpoch = 4
        frames[1].source = .sceneDepth
        frames[1].examinedSampleCount = 900
        frames[1].lowConfidenceSampleCount = 12
        frames[1].outOfRangeSampleCount = 7
        frames[1].highConfidenceSampleCount = 300
        frames[2].cameraPosition = nil
        let result = LiDARScanRecording.LiveResult(
            reportedDimensionsCM: ObjectDimensions(length: 8, width: 4, height: 6),
            decision: .notStarted,
            evidence: LiDARMeasurementEvidence(),
            shownDimensionsCM: ObjectDimensions(length: 8.1, width: 4, height: 6),
            shownStatus: LiDARAcceptanceStatus.qualified.rawValue
        )

        let url = try record(frames, region: region, result: result)
        let recording = try LiDARScanRecording(contentsOf: url)

        var expectedHeader = header(region)
        expectedHeader.recorderMarginMetres = configuration.cropMargin + 2 * configuration.voxelSize
        XCTAssertEqual(recording.header, expectedHeader)
        XCTAssertEqual(recording.region, region)
        XCTAssertEqual(recording.seed, SyntheticRegions.seed())
        XCTAssertEqual(recording.liveResult, result)
        XCTAssertEqual(recording.frames.count, 3)
        XCTAssertEqual(recording.omittedPointCounts, [0, 0, 0])
        for (read, written) in zip(recording.frames, frames) {
            XCTAssertEqual(read.points, written.points)
            XCTAssertEqual(read.timestamp, written.timestamp)
            XCTAssertEqual(read.tracking, written.tracking)
            XCTAssertEqual(read.coordinateEpoch, written.coordinateEpoch)
            XCTAssertEqual(read.cameraPosition, written.cameraPosition)
            XCTAssertEqual(read.source, written.source)
            XCTAssertEqual(read.examinedSampleCount, written.examinedSampleCount)
            XCTAssertEqual(read.lowConfidenceSampleCount, written.lowConfidenceSampleCount)
            XCTAssertEqual(read.outOfRangeSampleCount, written.outOfRangeSampleCount)
            XCTAssertEqual(read.highConfidenceSampleCount, written.highConfidenceSampleCount)
        }
    }

    func testBoxRegionRoundTrips() {
        let region = LiDARSpatialRegion.box(LiDARScanVolume(
            centre: SIMD3<Float>(0.1, 0.2, 0.3),
            axisX: SIMD3<Float>(0, 0, 1),
            axisY: SIMD3<Float>(0, 1, 0),
            axisZ: SIMD3<Float>(-1, 0, 0),
            halfExtents: SIMD3<Float>(0.1, 0.05, 0.2)
        ))
        XCTAssertEqual(LiDARScanRecording.Region(region).spatialRegion, region)
    }

    func testOnlyRaysThatMissTheRegionAreLeftOutAndTheyAreCounted() throws {
        var frames = boxFrames(count: 2)
        let kept = frames[0].points.count
        let camera = try XCTUnwrap(frames[0].cameraPosition)
        // Far behind the camera, and far to one side: neither ray comes near.
        frames[0].points.append(camera + (camera - SIMD3<Float>(0, 0.03, 0)) * 4)
        frames[0].points.append(SIMD3<Float>(5, 0.4, 5))
        // Beyond the region along a ray that passes through it: kept, since
        // it shows the space it crossed to be empty.
        let through = SIMD3<Float>(0, 0.03, 0)
        frames[0].points.append(camera + (through - camera) * 3)
        // Without a camera position every point is kept.
        frames[1].cameraPosition = nil
        frames[1].points.append(SIMD3<Float>(5, 0.4, 5))

        let recording = try LiDARScanRecording(
            contentsOf: record(frames, region: SyntheticRegions.prism(), result: nil)
        )

        XCTAssertEqual(recording.omittedPointCounts, [2, 0])
        XCTAssertEqual(recording.frames[0].points.count, kept + 1)
        XCTAssertEqual(recording.frames[1].points, frames[1].points)
        XCTAssertNil(recording.liveResult)
    }

    func testFileCutShortKeepsTheFramesBeforeTheCut() throws {
        let url = try record(boxFrames(count: 3), region: SyntheticRegions.prism(), result: nil)
        let whole = try Data(contentsOf: url)
        let recording = try LiDARScanRecording(data: whole.prefix(whole.count - 10))

        XCTAssertEqual(recording.frames.count, 2)
        XCTAssertNil(recording.liveResult)
    }

    func testOtherFilesAreRejected() {
        XCTAssertThrowsError(try LiDARScanRecording(data: Data("not a scan".utf8))) {
            XCTAssertEqual($0 as? LiDARScanRecording.ReadError, .notARecording)
        }
        var wrongVersion = Data("WLSC".utf8)
        withUnsafeBytes(of: UInt32(99)) { wrongVersion.append(contentsOf: $0) }
        XCTAssertThrowsError(try LiDARScanRecording(data: wrongVersion)) {
            XCTAssertEqual($0 as? LiDARScanRecording.ReadError, .unsupportedVersion(99))
        }
    }

    func testFileNamesAreSafeAndSortByTime() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(
            LiDARScanRecordingSettings.fileName(product: " Tea box/#3 ", step: "neighbour 10mm", date: date),
            "Tea-box-3_neighbour-10mm_20251009-085320.wlscan"
        )
        XCTAssertEqual(
            LiDARScanRecordingSettings.fileName(product: "", step: "../..", date: date),
            "unnamed_scan_20251009-085320.wlscan"
        )
        XCTAssertEqual(
            LiDARScanRecordingSettings.fileName(product: "a", step: "b", date: date, attempt: 1),
            "a_b_20251009-085320-2.wlscan"
        )
    }

    func testARecordingIsNeverWrittenOverAnExistingFile() throws {
        let region = SyntheticRegions.prism()
        let url = try record(boxFrames(count: 2), region: region, result: nil)

        XCTAssertThrowsError(try LiDARScanRecorder(
            url: url,
            header: header(region),
            region: region,
            margin: 0.009
        ))
        XCTAssertEqual(try LiDARScanRecording(contentsOf: url).frames.count, 2)
    }

    func testReplayingARecordingReproducesTheScanItWasMadeFrom() throws {
        let region = SyntheticRegions.prism()
        var frames = boxFrames(count: 24)
        // Returns well outside the region, as a real depth map carries.
        for index in frames.indices {
            for step in 0..<50 {
                frames[index].points.append(SIMD3<Float>(3 + Float(step) * 0.01, 0.5, -2))
            }
        }
        let session = LiDARMeasurementSession(configuration: configuration)
        session.begin(region: region, seed: SyntheticRegions.seed())
        for frame in frames { session.process(frame) }
        let live = session.report
        XCTAssertEqual(live.decision.status, .accepted)

        let url = try record(frames, region: region, result: LiDARScanRecording.LiveResult(
            reportedDimensionsCM: live.reportedDimensionsCM,
            decision: live.decision,
            evidence: live.evidence
        ))
        let recording = try LiDARScanRecording(contentsOf: url)
        XCTAssertEqual(recording.omittedPointCounts, [Int](repeating: 50, count: 24))

        let scans = MeasurementReplay.run(
            recordings: [(url.lastPathComponent, recording)],
            truths: ReplayGroundTruth.parse(csv: """
                product,length_cm,width_cm,height_cm,notes
                # measured with calipers
                Tea Box, 4.0, 8.0, 6.0, widths in either order
                broken,row
                """)
        )

        let scan = try XCTUnwrap(scans.first)
        XCTAssertEqual(scan.results.count, MeasurementReplay.variants.count)
        XCTAssertEqual(scan.results[0].dimensions, live.reportedDimensionsCM)
        XCTAssertEqual(scan.results[0].status, live.decision.status)
        XCTAssertEqual(MeasurementReplay.reproducesLiveResult(scan), true)
        XCTAssertEqual(scan.truth, ObjectDimensions(length: 8, width: 4, height: 6))

        let accuracy = MeasurementReplay.accuracy(scans, variant: 0)
        XCTAssertEqual(accuracy.offered, 1)
        XCTAssertLessThan(try XCTUnwrap(accuracy.worstAbsoluteErrorCM), 0.7)
        // Measuring height from the retained points reads short.
        let ablated = MeasurementReplay.accuracy(scans, variant: 1)
        XCTAssertLessThan(
            try XCTUnwrap(ablated.heightSignedErrorCM),
            try XCTUnwrap(accuracy.heightSignedErrorCM) - 0.3
        )

        let markdown = MeasurementReplay.markdown(scans: scans)
        XCTAssertTrue(markdown.contains("DEVICE RECORDINGS"))
        XCTAssertTrue(markdown.contains("reproduced the app's stored result for\n  1 of 1 scans"))
        XCTAssertTrue(markdown.contains("## Test: accuracy"))
    }

    // MARK: Helpers

    private func header(_ region: LiDARSpatialRegion) -> LiDARScanRecording.Header {
        let seed = SyntheticRegions.seed()
        return LiDARScanRecording.Header(
            label: "tea box",
            step: "accuracy",
            createdAt: "2026-10-10T00:00:00Z",
            deviceModel: "synthetic",
            systemVersion: "0",
            region: LiDARScanRecording.Region(region),
            seed: [seed.x, seed.y, seed.z]
        )
    }

    private func record(
        _ frames: [LiDARDepthFrame],
        region: LiDARSpatialRegion,
        result: LiDARScanRecording.LiveResult?
    ) throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).wlscan")
        let recorder = try LiDARScanRecorder(
            url: url,
            header: header(region),
            region: region,
            margin: configuration.cropMargin + 2 * configuration.voxelSize
        )
        for frame in frames { recorder.append(frame) }
        XCTAssertEqual(recorder.frameCount, frames.count)
        if result == nil {
            // Simulates the app closing mid-scan: the file is simply released.
            return url
        }
        recorder.finish(result: result)
        return url
    }

    private func boxFrames(count: Int) -> [LiDARDepthFrame] {
        SyntheticScanner.frames(
            scene: SyntheticScene(
                objects: [SyntheticObject(
                    shape: .box(size: SIMD3<Float>(0.08, 0.06, 0.04)),
                    baseCentre: .zero
                )],
                supportHalfExtent: 0.10
            ),
            plan: SyntheticScanPlan(frameCount: count)
        )
    }
}
