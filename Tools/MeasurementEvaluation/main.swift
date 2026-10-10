import Foundation

// Command-line entry point for the SYNTHETIC measurement evaluation.
// Built and run by scripts/evaluate-measurement.sh; not part of the app.
//
// Usage: evaluate-measurement [output.md] [generator-seed] [provenance]

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 && !arguments[1].isEmpty ? arguments[1] : nil
var generatorSeed: UInt64 = 20_261_009
if arguments.count > 2 {
    guard let parsed = UInt64(arguments[2]) else {
        FileHandle.standardError.write(Data("Invalid generator seed: \(arguments[2])\n".utf8))
        exit(2)
    }
    generatorSeed = parsed
}
let provenance = arguments.count > 3 ? arguments[3] : nil

let cases = MeasurementEvaluation.cases(generatorSeed: generatorSeed, scale: .full)
let outcomes = MeasurementEvaluation.run(cases)
let summary = MeasurementEvaluation.summarize(outcomes, generatorSeed: generatorSeed)
let markdown = MeasurementEvaluation.markdown(
    summary: summary,
    outcomes: outcomes,
    provenance: provenance
)

if let outputPath {
    try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Wrote SYNTHETIC evaluation (not device accuracy) to \(outputPath)")
} else {
    print(markdown)
}
