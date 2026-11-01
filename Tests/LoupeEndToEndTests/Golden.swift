import Foundation
import Testing

/// Compares rendered output with a file under `Goldens/` next to the calling test file. The messages
/// are the product, so any wording change must show up in review as a golden diff.
/// Regenerate with `LOUPE_UPDATE_GOLDENS=1 swift test`.
func assertGolden(_ actual: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation, file: String = #filePath) throws {
    let directory = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Goldens")
    let url = directory.appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["LOUPE_UPDATE_GOLDENS"] != nil {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try actual.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("No golden file \(name). Create it with LOUPE_UPDATE_GOLDENS=1 swift test.", sourceLocation: sourceLocation)
        return
    }
    #expect(actual == expected, "Output differs from Goldens/\(name). If the change is intended, regenerate with LOUPE_UPDATE_GOLDENS=1 swift test.", sourceLocation: sourceLocation)
}
