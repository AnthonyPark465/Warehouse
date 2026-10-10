import Foundation

// Command-line entry point for the DEVICE replay: scans recorded by the app
// are run through the pipeline again, once per variant. Built and run by
// scripts/replay-measurement.sh; not part of the app.
//
// Usage: replay-measurement <recordings-folder> [ground-truth.csv] [output.md] [provenance]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    fail("Usage: replay-measurement <recordings-folder> [ground-truth.csv] [output.md]")
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let truthPath = arguments.count > 2 && !arguments[2].isEmpty ? arguments[2] : nil
let outputPath = arguments.count > 3 && !arguments[3].isEmpty ? arguments[3] : nil
let provenance = arguments.count > 4 ? arguments[4] : nil

let files: [URL]
do {
    files = try FileManager.default
        .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == LiDARScanRecording.fileExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    fail("Cannot read \(folder.path): \(error.localizedDescription)")
}
guard !files.isEmpty else {
    fail("No .\(LiDARScanRecording.fileExtension) files in \(folder.path)")
}

var truths: [ReplayGroundTruth] = []
if let truthPath {
    guard let csv = try? String(contentsOfFile: truthPath, encoding: .utf8) else {
        fail("Cannot read ground truth at \(truthPath)")
    }
    truths = ReplayGroundTruth.parse(csv: csv)
    if truths.isEmpty {
        fail("No usable rows in \(truthPath). Expected: product,length_cm,width_cm,height_cm")
    }
}

var recordings: [(fileName: String, recording: LiDARScanRecording)] = []
for file in files {
    do {
        recordings.append((file.lastPathComponent, try LiDARScanRecording(contentsOf: file)))
    } catch {
        FileHandle.standardError.write(Data("Skipping \(file.lastPathComponent): \(error)\n".utf8))
    }
}
guard !recordings.isEmpty else { fail("None of the recordings could be read.") }

let scans = MeasurementReplay.run(recordings: recordings, truths: truths)
let known = Set(truths.map { ReplayGroundTruth.key($0.product) })
let unmatched = Set(scans.filter { $0.truth == nil }.map(\.recording.header.label)).sorted()
if !truths.isEmpty, !unmatched.isEmpty {
    FileHandle.standardError.write(Data(
        "No ground truth for product name(s): \(unmatched.map { "\"\($0)\"" }.joined(separator: ", ")). Known: \(known.sorted().joined(separator: ", "))\n".utf8
    ))
}

let markdown = MeasurementReplay.markdown(scans: scans, provenance: provenance)
if let outputPath {
    try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Wrote device replay of \(scans.count) scans to \(outputPath)")
} else {
    print(markdown)
}
