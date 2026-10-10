import Foundation

/// Central configuration for measurement uncertainty and warehouse clearance.
/// Future device-, warehouse-, or confidence-specific providers can supply a
/// different policy without changing AddProduct or the 3D viewer.
struct ObjectDimensionPolicy: Equatable {
    let fixedToleranceCM: Double
    let percentageTolerance: Double
    let storageClearanceCM: Double

    static let `default` = ObjectDimensionPolicy(
        fixedToleranceCM: 0.5,
        percentageTolerance: 0.02,
        storageClearanceCM: 0
    )
}

enum ObjectDimensionCalculator {
    static let internalUnit = "cm"

    static func makeRecord(
        capture: ObjectScanCapture,
        displayUnit: DimensionDisplayUnit,
        canBeRotated: Bool,
        useAdjustedDimensions: Bool = true,
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
        let adjusted = ObjectDimensions(
            length: raw.length + tolerance.length + clearance.length,
            width: raw.width + tolerance.width + clearance.width,
            height: raw.height + tolerance.height + clearance.height
        )
        let final = useAdjustedDimensions ? adjusted : raw

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
            scanTimestamp: capture.timestamp,
            percentageTolerance: policy.percentageTolerance,
            fixedToleranceCM: policy.fixedToleranceCM,
            usesAdjustedDimensions: useAdjustedDimensions,
            measurementQuality: quality(for: capture.confidence),
            manualMeasurement: capture.manualMeasurement,
            measurementEvidence: capture.measurementEvidence
        )
    }

    static func tolerance(
        for measuredCM: Double,
        policy: ObjectDimensionPolicy = .default
    ) -> Double {
        measuredCM * policy.percentageTolerance + policy.fixedToleranceCM
    }

    static func quality(for confidence: Double) -> MeasurementQuality {
        switch confidence {
        case 0.8...: .good
        case 0.65..<0.8: .acceptable
        case 0.5..<0.65: .low
        default: .repeatRecommended
        }
    }
}

enum DimensionUnitConverter {
    static func displayValue(_ centimetres: Double, unit: DimensionDisplayUnit) -> Double {
        switch unit {
        case .centimetres: centimetres
        case .metres: centimetres / 100
        }
    }

    /// Dimensions are shown to the nearest millimetre in either unit. Depth
    /// fusion works on a 3 mm grid, so finer digits would imply precision
    /// the measurement does not have.
    static func fractionDigits(for unit: DimensionDisplayUnit) -> Int {
        switch unit {
        case .centimetres: 1
        case .metres: 3
        }
    }

    static func formatted(_ centimetres: Double, unit: DimensionDisplayUnit) -> String {
        let value = displayValue(centimetres, unit: unit)
        return "\(value.formatted(.number.precision(.fractionLength(fractionDigits(for: unit))))) \(unit.rawValue)"
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
