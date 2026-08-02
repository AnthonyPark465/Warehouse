import Foundation
import simd

struct PlacementVerification: Equatable {
    enum Stage: Equatable {
        case scanProduct
        case scanLocation
        case complete
        case failed(message: String)
    }

    let expectedProductBarcode: String
    let expectedLocationBarcode: String
    private(set) var stage: Stage = .scanProduct

    mutating func accept(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .scanProduct:
            stage = value == expectedProductBarcode
                ? .scanLocation
                : .failed(message: "Wrong product. Scan \(expectedProductBarcode).")
        case .scanLocation:
            stage = value == expectedLocationBarcode
                ? .complete
                : .failed(message: "Wrong location. Scan \(expectedLocationBarcode).")
        case .complete:
            break
        case .failed:
            stage = .scanProduct
            accept(value)
        }
    }

    mutating func retry() {
        stage = .scanProduct
    }
}

struct PlacementVerificationConfiguration: Equatable {
    var positionToleranceCM: Double = 4
    var rotationToleranceDegrees: Double = 8
    static let warehouse = PlacementVerificationConfiguration()
}

enum ARPlacementVerificationResult: Equatable {
    case verified(positionErrorCM: Double, rotationErrorDegrees: Double)
    case correction(message: String, offsetCM: Vector3D, rotationDegrees: Double)
    case unavailable(message: String)
}

enum ARPlacementVerifier {
    static func verify(
        expectedPosition: Vector3D,
        expectedQuarterTurns: Int,
        actualPosition: Vector3D?,
        actualYawDegrees: Double?,
        trackingAvailable: Bool,
        configuration: PlacementVerificationConfiguration = .warehouse
    ) -> ARPlacementVerificationResult {
        guard trackingAvailable, let actualPosition, let actualYawDegrees else {
            return .unavailable(message: "AR tracking is unavailable. Reopen the shelf scan or verify the location barcode manually.")
        }
        let offset = expectedPosition.simd - actualPosition.simd
        let positionError = simd_length(offset)
        let targetYaw = Double((expectedQuarterTurns % 4 + 4) % 4) * 90
        var rotationError = targetYaw - actualYawDegrees.truncatingRemainder(dividingBy: 360)
        if rotationError > 180 { rotationError -= 360 }
        if rotationError < -180 { rotationError += 360 }
        guard positionError <= configuration.positionToleranceCM,
              abs(rotationError) <= configuration.rotationToleranceDegrees else {
            var moves: [String] = []
            if abs(offset.x) > 0.5 { moves.append("move \(abs(offset.x).formatted(.number.precision(.fractionLength(0)))) cm \(offset.x > 0 ? "right" : "left")") }
            if abs(offset.y) > 0.5 { moves.append("move \(abs(offset.y).formatted(.number.precision(.fractionLength(0)))) cm \(offset.y > 0 ? "up" : "down")") }
            if abs(offset.z) > 0.5 { moves.append("move \(abs(offset.z).formatted(.number.precision(.fractionLength(0)))) cm \(offset.z > 0 ? "toward the back" : "toward the front")") }
            if abs(rotationError) > configuration.rotationToleranceDegrees {
                moves.append("rotate \(abs(rotationError).formatted(.number.precision(.fractionLength(0))))° \(rotationError > 0 ? "clockwise" : "counter-clockwise")")
            }
            let combined = moves.joined(separator: " and ")
            let message = combined.prefix(1).uppercased() + String(combined.dropFirst()) + "."
            return .correction(message: message, offsetCM: Vector3D(offset), rotationDegrees: rotationError)
        }
        return .verified(positionErrorCM: positionError, rotationErrorDegrees: abs(rotationError))
    }
}
