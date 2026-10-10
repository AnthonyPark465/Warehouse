import Foundation

// Command-line entry point for the SYNTHETIC placement evaluation.
// Built and run by scripts/evaluate-placement.sh; not part of the app.
//
// Usage: evaluate-placement [output.md] [generator-seed] [provenance]

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

let (outcomes, timings) = PlacementEvaluation.runAll(generatorSeed: generatorSeed, scale: .full)
let markdown = PlacementEvaluation.markdown(
    summaries: PlacementEvaluation.summarize(outcomes),
    timings: timings,
    generatorSeed: generatorSeed,
    scale: .full,
    provenance: provenance
)

if let outputPath {
    try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Wrote SYNTHETIC placement evaluation (not a real stock room) to \(outputPath)")
} else {
    print(markdown)
}
