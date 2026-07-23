import Foundation

/// Values for barcodes the app generates itself (rendered as Code 128).
/// Format: "WH" + zero-padded counter, e.g. "WH0000000042".
enum BarcodeValue {
    static let generatedPrefix = "WH"
    static let generatedDigits = 10

    static func generated(counter: Int) -> String {
        // Manual zero-padding: String(format: "%0Nd") truncates beyond Int32.
        let digits = String(counter)
        let padding = String(repeating: "0", count: max(0, generatedDigits - digits.count))
        return generatedPrefix + padding + digits
    }

    static func isGenerated(_ value: String) -> Bool {
        value.hasPrefix(generatedPrefix)
            && value.count == generatedPrefix.count + generatedDigits
            && value.dropFirst(generatedPrefix.count).allSatisfy(\.isNumber)
    }
}
