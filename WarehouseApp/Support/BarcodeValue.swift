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

    /// Rules for externally supplied (scanned or typed) values. The value becomes a
    /// Firestore document ID, so "/" and the reserved "."/".." names must be rejected
    /// or the write crashes with an invalid document path.
    static let maxExternalLength = 100
    private static let externalAllowedScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~:@+-"
    )

    static func isValidExternal(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxExternalLength else { return false }
        guard value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy(externalAllowedScalars.contains)
    }
}
