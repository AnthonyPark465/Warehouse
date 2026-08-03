import XCTest
import simd
@testable import WarehouseApp

final class SurfaceFirstCompartmentMeasurementTests: XCTestCase {
    private let epoch = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!

    func testFitsBottomBackAndLeftIndependentlyWithNoise() throws {
        let volume = target()
        let configuration = testConfiguration()
        for surface in [CompartmentSurface.bottom, .back, .left] {
            let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
                surface: surface, observations: observations(for: surface),
                targetVolume: volume, selectedRegionSeed: seed(for: surface),
                configuration: configuration
            )))
            XCTAssertEqual(fit.surface, surface)
            XCTAssertGreaterThanOrEqual(fit.fittedPlane.inlierCount, configuration.minimumInliers)
            XCTAssertLessThan(fit.fittedPlane.rmsResidualMetres, 0.004)
            XCTAssertGreaterThan(fit.coverageFirstAxisMetres, 0.09)
            XCTAssertGreaterThan(fit.coverageSecondAxisMetres, 0.09)
        }
    }

    func testThreePlaneCornerAndUncertaintyPropagation() throws {
        let volume = target()
        let bottom = plane(.bottom, origin: .init(0, 0, 0), normal: .init(0, 1, 0), uncertainty: 0.003)
        let back = plane(.back, origin: .init(0, 0, 0.8), normal: .init(0, 0, 1), uncertainty: 0.004)
        let left = plane(.left, origin: .init(-0.4, 0, 0), normal: .init(1, 0, 0), uncertainty: 0.005)
        let corner = try XCTUnwrap(success(CompartmentPlaneGeometry.intersect(
            bottom, back, left, targetVolume: volume
        )))
        XCTAssertEqual(corner.position.x, -0.4, accuracy: 1e-9)
        XCTAssertEqual(corner.position.y, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.position.z, 0.8, accuracy: 1e-9)
        XCTAssertEqual(corner.uncertaintyMetres, sqrt(0.003 * 0.003 + 0.004 * 0.004 + 0.005 * 0.005), accuracy: 1e-9)
        XCTAssertEqual(corner.supportingSurfaces, [.bottom, .back, .left])
    }

    func testFloorBelowShelfIsRejectedByTargetVolume() throws {
        var volume = target()
        volume.centre.y = 0.42
        volume.halfExtents.y = 0.18
        let shelf = observations(for: .bottom, offset: .init(0, 0.4, 0))
        let floor = observations(for: .bottom, offset: .init(0, -0.35, 0), idOffset: 2_000)
        let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: shelf + floor,
            targetVolume: volume, selectedRegionSeed: .init(0, 0.4, 0.5),
            configuration: testConfiguration()
        )))
        XCTAssertEqual(fit.fittedPlane.plane.origin.y, 0.4, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(fit.rejectedObservationCount, floor.count)
    }

    func testSeparatedHorizontalShelfWinsOverFloorAtSelectedHeight() throws {
        var volume = target(); volume.halfExtents.y = 0.7
        let shelf = observations(for: .bottom, offset: .init(0, 0.35, 0))
        let floor = observations(for: .bottom, offset: .init(0, -0.25, 0), idOffset: 2_000)
        let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: shelf + floor,
            targetVolume: volume, selectedRegionSeed: .init(0, 0.35, 0.5),
            configuration: testConfiguration()
        )))
        XCTAssertEqual(fit.fittedPlane.plane.origin.y, 0.35, accuracy: 0.015)
    }

    func testUnrelatedVerticalObjectDoesNotReplaceConnectedSideWall() throws {
        let wall = observations(for: .left)
        let object = Array(observations(for: .left, offset: .init(0.32, 0, -0.20), idOffset: 3_000).prefix(18))
        let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
            surface: .left, observations: wall + object, targetVolume: target(),
            selectedRegionSeed: seed(for: .left), configuration: testConfiguration()
        )))
        XCTAssertEqual(fit.fittedPlane.plane.origin.x, -0.4, accuracy: 0.02)
    }

    func testDisconnectedCompetingWallsRequireRescan() {
        let first = observations(for: .back, offset: .init(-0.18, 0, 0))
        let second = observations(for: .back, offset: .init(0.18, 0, -0.06), idOffset: 4_000)
        let result = SurfaceFirstPlaneEstimator.fit(
            surface: .back, observations: first + second, targetVolume: target(),
            selectedRegionSeed: .init(0, 0.25, 0.77), configuration: testConfiguration()
        )
        XCTAssertEqual(failure(result), .ambiguousSurfaces)
    }

    func testBottomIgnoresDisconnectedBoxContamination() throws {
        let bottom = observations(for: .bottom)
        let box = Array(observations(for: .bottom, offset: .init(0.25, 0.10, 0.05), idOffset: 5_000).prefix(16))
        let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: bottom + box, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )))
        XCTAssertEqual(fit.fittedPlane.plane.origin.y, 0, accuracy: 0.015)
    }

    func testInsufficientCoverageIsRejected() {
        var configuration = testConfiguration(); configuration.minimumCoveragePerAxisMetres = 0.10
        let samples = observations(for: .bottom, gridSpacing: 0.008)
        XCTAssertEqual(failure(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: samples, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: configuration
        )), .insufficientCoverage)
    }

    func testInsufficientViewDiversityIsRejected() {
        var samples = observations(for: .bottom)
        for index in samples.indices {
            samples[index].cameraPosition = .init(0, 0.45, -0.5)
            samples[index].viewingDirection = .init(0, -0.4, 1)
            samples[index].timestamp = Double(samples[index].frameSequence) * 0.6
        }
        XCTAssertEqual(failure(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: samples, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )), .insufficientIndependentViews)
    }

    func testDuplicatedCorrelatedSamplesDoNotCreateIndependentViews() {
        let original = observations(for: .bottom, frameCount: 1)
        var duplicates: [SurfaceCaptureObservation] = []
        for frame in 0..<5 {
            duplicates += original.map {
                var copy = $0
                copy.id = UUID()
                copy.frameSequence = frame
                copy.timestamp = Double(frame) * 0.1
                return copy
            }
        }
        XCTAssertEqual(failure(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: duplicates, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )), .insufficientIndependentViews)
    }

    func testMixedCoordinateEpochIsRejected() {
        var samples = observations(for: .bottom)
        samples[samples.count / 2].coordinateEpoch = UUID()
        XCTAssertEqual(failure(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: samples, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )), .mixedCoordinateEpoch)
    }

    func testReflectiveLowConfidenceAndWarpedDepthAreRejected() {
        var reflective = observations(for: .bottom)
        for index in reflective.indices { reflective[index].depthConfidence = 0.1 }
        XCTAssertNil(success(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: reflective, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )))

        var warped = observations(for: .bottom)
        for index in warped.indices {
            let x = warped[index].position.x
            warped[index].position.y += x * x * 12
        }
        XCTAssertNil(success(SurfaceFirstPlaneEstimator.fit(
            surface: .bottom, observations: warped, targetVolume: target(),
            selectedRegionSeed: seed(for: .bottom), configuration: testConfiguration()
        )))
    }

    func testNearlyParallelPlanesAndOutsideCornerAreRejected() {
        let volume = target()
        let a = plane(.bottom, origin: .init(0, 0, 0), normal: .init(0, 1, 0))
        let b = plane(.back, origin: .init(0, 0, 0.5), normal: .init(0, 0.999, 0.04))
        let c = plane(.left, origin: .init(-0.4, 0, 0), normal: .init(1, 0, 0))
        XCTAssertEqual(failure(CompartmentPlaneGeometry.intersect(a, b, c, targetVolume: volume)),
                       .illConditionedIntersection)

        let far = plane(.back, origin: .init(0, 0, 3), normal: .init(0, 0, 1))
        XCTAssertEqual(failure(CompartmentPlaneGeometry.intersect(a, far, c, targetVolume: volume)),
                       .cornerOutsideTargetVolume)
    }

    func testRescanningOnePlaneOnlyMovesSupportedCorners() throws {
        let volume = target()
        let bottom = plane(.bottom, origin: .init(0, 0, 0), normal: .init(0, 1, 0))
        let back = plane(.back, origin: .init(0, 0, 0.8), normal: .init(0, 0, 1))
        let leftA = plane(.left, origin: .init(-0.4, 0, 0), normal: .init(1, 0, 0))
        let leftB = plane(.left, origin: .init(-0.35, 0, 0), normal: .init(1, 0, 0))
        let right = plane(.right, origin: .init(0.4, 0, 0), normal: .init(-1, 0, 0))
        let beforeLeft = try XCTUnwrap(success(CompartmentPlaneGeometry.intersect(bottom, back, leftA, targetVolume: volume)))
        let afterLeft = try XCTUnwrap(success(CompartmentPlaneGeometry.intersect(bottom, back, leftB, targetVolume: volume)))
        let beforeRight = try XCTUnwrap(success(CompartmentPlaneGeometry.intersect(bottom, back, right, targetVolume: volume)))
        let afterRight = try XCTUnwrap(success(CompartmentPlaneGeometry.intersect(bottom, back, right, targetVolume: volume)))
        XCTAssertNotEqual(beforeLeft.position, afterLeft.position)
        XCTAssertEqual(beforeRight.position, afterRight.position)
    }

    func testOpeningIsSeparateFromInteriorAndTaperIsNotCorrected() throws {
        let planes = [
            plane(.bottom, origin: .init(0, 0, 0), normal: .init(0, 1, 0)),
            plane(.top, origin: .init(0, 0.5, 0), normal: .init(0, -1, 0)),
            plane(.back, origin: .init(0, 0, 0.8), normal: .init(0, 0, 1)),
            plane(.frontOpening, origin: .init(0, 0, 0.1), normal: .init(0, 0, -1)),
            plane(.left, origin: .init(-0.4, 0, 0), normal: .init(1, 0, 0)),
            plane(.right, origin: .init(0.4, 0, 0), normal: .init(-1, 0, 0))
        ]
        let dimensions = try XCTUnwrap(CompartmentPlaneGeometry.dimensions(
            planes: planes, verifiedOpeningWidthMetres: 0.72, verifiedOpeningHeightMetres: 0.44
        ))
        XCTAssertEqual(dimensions.interiorWidthMetres, 0.8, accuracy: 1e-9)
        XCTAssertEqual(dimensions.openingWidthMetres, 0.72)
        XCTAssertTrue(dimensions.hasVerifiedUsableOpening)

        let assessment = RectangularCompartmentEvaluator.evaluate(
            planes: planes, frontOpeningWidthMetres: 0.72, interiorWidthMetres: 0.8
        )
        XCTAssertTrue(assessment.isTapered)
        XCTAssertEqual(assessment.approval, .rejected)

        var contradictoryFront = planes
        contradictoryFront[3] = plane(
            .frontOpening, origin: .init(0, 0, 0.1), normal: .init(0.25, 0, -0.97)
        )
        XCTAssertEqual(
            RectangularCompartmentEvaluator.evaluate(planes: contradictoryFront).approval,
            .rejected
        )
    }

    func testAdaptivePixelRegionPreservesPhysicalCoverageAtCloseRange() {
        let close = AdaptiveDepthSampling.pixelRadius(seedDepthMetres: 0.25, focalLengthPixels: 250)
        let distant = AdaptiveDepthSampling.pixelRadius(seedDepthMetres: 2.0, focalLengthPixels: 250)
        XCTAssertGreaterThan(close, distant)
        XCTAssertEqual(close, SurfaceCaptureConfiguration.standard.maximumPixelRadius)
        XCTAssertGreaterThanOrEqual(distant, SurfaceCaptureConfiguration.standard.minimumPixelRadius)
    }

    func testDistantObservationsOutsideVolumeAreIgnored() throws {
        let intended = observations(for: .back)
        let background = observations(for: .back, offset: .init(0, 0, 1.4), idOffset: 8_000)
        let fit = try XCTUnwrap(success(SurfaceFirstPlaneEstimator.fit(
            surface: .back, observations: intended + background, targetVolume: target(),
            selectedRegionSeed: seed(for: .back), configuration: testConfiguration()
        )))
        XCTAssertEqual(fit.fittedPlane.plane.origin.z, 0.8, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(fit.rejectedObservationCount, background.count)
    }

    private func target() -> LocalTargetVolume {
        .init(centre: .init(0, 0.3, 0.45), halfExtents: .init(0.75, 0.75, 0.75),
              coordinateEpoch: epoch, seedDepthMetres: 0.8)
    }

    private func testConfiguration() -> SurfaceCaptureConfiguration {
        var value = SurfaceCaptureConfiguration.standard
        value.minimumIndependentViews = 4
        value.minimumInliers = 20
        value.minimumCoveragePerAxisMetres = 0.08
        value.deduplicationVoxelMetres = 0.004
        value.connectivityDistanceMetres = 0.055
        return value
    }

    private func seed(for surface: CompartmentSurface) -> Vector3D {
        switch surface {
        case .bottom: .init(0, 0, 0.5)
        case .back: .init(0, 0.25, 0.8)
        case .left: .init(-0.4, 0.25, 0.5)
        case .right: .init(0.4, 0.25, 0.5)
        case .top: .init(0, 0.5, 0.5)
        case .frontOpening: .init(0, 0.25, 0.1)
        }
    }

    private func observations(
        for surface: CompartmentSurface,
        offset: Vector3D = .init(0, 0, 0),
        idOffset: Int = 0,
        frameCount: Int = 5,
        gridSpacing: Double = 0.035
    ) -> [SurfaceCaptureObservation] {
        var result: [SurfaceCaptureObservation] = []
        for frame in 0..<frameCount {
            let camera = SIMD3<Double>(-0.16 + Double(frame) * 0.08, 0.35, -0.35 + Double(frame) * 0.012)
            for row in -2...2 {
                for column in -2...2 {
                    let jitter = Double((row * 7 + column * 11 + frame * 3) % 5) * 0.0003
                    var point: SIMD3<Double>
                    switch surface {
                    case .bottom:
                        point = .init(Double(column) * gridSpacing, jitter,
                                      0.5 + Double(row) * gridSpacing)
                    case .top:
                        point = .init(Double(column) * gridSpacing, 0.5 + jitter,
                                      0.5 + Double(row) * gridSpacing)
                    case .back:
                        point = .init(Double(column) * gridSpacing,
                                      0.25 + Double(row) * gridSpacing, 0.8 + jitter)
                    case .left:
                        point = .init(-0.4 + jitter, 0.25 + Double(row) * gridSpacing,
                                      0.5 + Double(column) * gridSpacing)
                    case .right:
                        point = .init(0.4 + jitter, 0.25 + Double(row) * gridSpacing,
                                      0.5 + Double(column) * gridSpacing)
                    case .frontOpening:
                        point = .init(Double(column) * gridSpacing,
                                      0.25 + Double(row) * gridSpacing, 0.1 + jitter)
                    }
                    point += offset.simd + SIMD3<Double>(Double(frame) * 0.0012, 0, 0)
                    let direction = simd_normalize(point - camera)
                    let serial = idOffset + frame * 25 + (row + 2) * 5 + column + 3
                    result.append(.init(
                        id: UUID(uuidString: String(format: "70000000-0000-0001-%04x-%012x", serial / 65_535, serial % 65_535)) ?? UUID(),
                        position: Vector3D(point), normal: nil,
                        cameraPosition: Vector3D(camera), viewingDirection: Vector3D(direction),
                        depthConfidence: 1, trackingState: .normal,
                        frameSequence: frame, timestamp: Double(frame) * 0.55,
                        coordinateEpoch: epoch
                    ))
                }
            }
        }
        return result
    }

    private func plane(
        _ surface: CompartmentSurface, origin: Vector3D, normal: Vector3D,
        uncertainty: Double = 0.004
    ) -> FittedCompartmentPlane {
        .init(surface: surface, plane: .init(origin: origin, normal: normal),
              rmsResidualMetres: 0.002, maximumResidualMetres: 0.004,
              uncertaintyMetres: uncertainty, sampleCoverageMetres: 0.3,
              viewingDiversityRadians: 0.2, inlierCount: 40, evidenceState: .accepted)
    }

    private func success<T, E>(_ result: Result<T, E>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func failure<T>(_ result: Result<T, SurfaceCaptureFailure>) -> SurfaceCaptureFailure? {
        if case .failure(let value) = result { return value }
        return nil
    }
}
