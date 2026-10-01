import Foundation

// Minimal assertion helper shared by the test executables built by scripts/ci.sh.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("  FAIL \(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line) \(message)\n".utf8))
    }
}

func finish(_ suite: String) -> Never {
    FileHandle.standardError.write(Data("  \(suite): \(checks - failures)/\(checks) checks passed\n".utf8))
    exit(failures == 0 ? 0 : 1)
}
