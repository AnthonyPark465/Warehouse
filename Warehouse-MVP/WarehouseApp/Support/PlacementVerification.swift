import Foundation

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

