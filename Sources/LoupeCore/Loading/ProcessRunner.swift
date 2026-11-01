import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunner {
    /// Runs `command` (found on PATH) and waits for it, without blocking a cooperative or dispatch
    /// worker thread.
    ///
    /// The two pipe reads and the wait each get their own thread. Blocking reads on dispatch's workers
    /// would let enough concurrent children exhaust the pool and deadlock on their own pipes, and
    /// `readabilityHandler` can miss the final end-of-file when a process exits, which hangs the caller.
    static func run(_ command: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let collector = Collector(continuation)
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            Thread.detachNewThread { collector.set(\.stdout, to: stdoutHandle.readDataToEndOfFile()) }
            Thread.detachNewThread { collector.set(\.stderr, to: stderrHandle.readDataToEndOfFile()) }
            Thread.detachNewThread {
                process.waitUntilExit()
                collector.set(\.status, to: process.terminationStatus)
            }
        }
    }

    /// Gathers the three parts of a child's result, and resumes the caller when all have arrived.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessResult, any Error>?
        private var result = ProcessResult(status: 0, stdout: Data(), stderr: Data())
        private var pending = 3

        init(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
            self.continuation = continuation
        }

        func set<Value>(_ part: WritableKeyPath<ProcessResult, Value>, to value: Value) {
            lock.lock()
            result[keyPath: part] = value
            pending -= 1
            let finished = pending == 0 ? continuation : nil
            if finished != nil { continuation = nil }
            let snapshot = result
            lock.unlock()
            finished?.resume(returning: snapshot)
        }
    }

    /// `swift package dump-package --package-path Core`, as a shell-ready string for error messages.
    static func shellCommand(_ command: String, _ arguments: [String]) -> String {
        ([command] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}
