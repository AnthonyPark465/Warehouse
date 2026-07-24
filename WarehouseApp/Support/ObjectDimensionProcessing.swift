import Foundation

/// Central configuration for measurement uncertainty and warehouse clearance.
/// Future device-, warehouse-, or confidence-specific providers can supply a
/// different policy without changing AddProduct or the 3D viewer.
struct ObjectDimensionPolicy: Equatable {
    let minimumToleranceCM: Double
    let proportionalTolerance: Double
    let storageClearanceCM: Double

    static let `default` = ObjectDimensionPolicy(
        minimumToleranceCM: 2,
        proportionalTolerance: 0.02,
        storageClearanceCM: 1
    )
}

enum ObjectDimensionCalculator {
    static let internalUnit = "cm"

    static func makeRecord(
        capture: ObjectScanCapture,
        displayUnit: DimensionDisplayUnit,
        canBeRotated: Bool,
        policy: ObjectDimensionPolicy = .default
    ) -> ProductObjectScan {
        let raw = capture.rawDimensionsCM
        let tolerance = ObjectDimensions(
            length: tolerance(for: raw.length, policy: policy),
            width: tolerance(for: raw.width, policy: policy),
            height: tolerance(for: raw.height, policy: policy)
        )
        let clearance = ObjectDimensions(
            length: policy.storageClearanceCM,
            width: policy.storageClearanceCM,
            height: policy.storageClearanceCM
        )
        let final = ObjectDimensions(
            length: raw.length + tolerance.length + clearance.length,
            width: raw.width + tolerance.width + clearance.width,
            height: raw.height + tolerance.height + clearance.height
        )

        return ProductObjectScan(
            rawLength: raw.length,
            rawWidth: raw.width,
            rawHeight: raw.height,
            scanToleranceLength: tolerance.length,
            scanToleranceWidth: tolerance.width,
            scanToleranceHeight: tolerance.height,
            storageClearanceLength: clearance.length,
            storageClearanceWidth: clearance.width,
            storageClearanceHeight: clearance.height,
            finalLength: final.length,
            finalWidth: final.width,
            finalHeight: final.height,
            displayUnit: displayUnit,
            internalUnit: internalUnit,
            canBeRotated: canBeRotated,
            scanMethod: capture.scanMethod,
            deviceModel: capture.deviceModel,
            hasLiDAR: capture.hasLiDAR,
            scanConfidence: capture.confidence,
            scanTimestamp: capture.timestamp
        )
    }

    static func tolerance(
        for measuredCM: Double,
        policy: ObjectDimensionPolicy = .default
    ) -> Double {
        max(policy.minimumToleranceCM, measuredCM * policy.proportionalTolerance)
    }
}

enum DimensionUnitConverter {
    static func displayValue(_ centimetres: Double, unit: DimensionDisplayUnit) -> Double {
        switch unit {
        case .centimetres: centimetres
        case .metres: centimetres / 100
        }
    }

    static func formatted(_ centimetres: Double, unit: DimensionDisplayUnit) -> String {
        let value = displayValue(centimetres, unit: unit)
        return "\(value.formatted(.number.precision(.fractionLength(2)))) \(unit.rawValue)"
    }
}

enum ObjectScanValidation {
    static let minimumDimensionCM: Double = 0.5
    static let maximumDimensionCM: Double = 500
    static let minimumConfidence: Double = 0.55
    static let minimumPointCount: Int = 120

    static func message(
        dimensions: ObjectDimensions,
        confidence: Double,
        pointCount: Int
    ) -> String? {
        guard dimensions.values.allSatisfy({ $0.isFinite }) else {
            return "The scan produced invalid measurements. Rescan the object."
        }
        guard dimensions.values.allSatisfy({ $0 > 0 }) else {
            return "All three dimensions must be greater than zero."
        }
        guard dimensions.values.allSatisfy({ $0 >= minimumDimensionCM }) else {
            return "The scan is incomplete on at least one axis. Move around the entire object and rescan."
        }
        guard dimensions.values.allSatisfy({ $0 <= maximumDimensionCM }) else {
            return "The measured volume is too large for reliable object isolation. Move closer and rescan."
        }
        guard pointCount >= minimumPointCount else {
            return "Not enough surface detail was captured. Move slowly around the object and rescan."
        }
        guard confidence >= minimumConfidence else {
            return "Scan quality is too low to save. Improve lighting, keep the object centred, and rescan."
        }
        return nil
    }

    static func storageBoxMessage(record: ProductObjectScan) -> String? {
        guard record.finalLength >= record.rawLength,
              record.finalWidth >= record.rawWidth,
              record.finalHeight >= record.rawHeight
        else {
            return "The storage bounding box cannot be smaller than the scanned object."
        }
        return nil
    }
}
