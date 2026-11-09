import Foundation

/// Thread-safe byte accumulator used while a child process streams output.
final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Splits streamed bytes into lines (on \n or \r) and forwards each complete line.
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let handler: ((String) -> Void)?

    init(handler: ((String) -> Void)?) { self.handler = handler }

    func feed(_ d: Data) {
        guard let handler else { return }
        lock.lock()
        pending.append(d)
        var lines: [String] = []
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(handler)
    }

    func flush() {
        guard let handler else { return }
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if let s = String(data: rest, encoding: .utf8), !s.isEmpty { handler(s) }
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String

    var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
}

enum ProcessRunner {
    /// Runs an executable asynchronously, streaming lines to the optional callbacks.
    /// Cancelling the calling task terminates the process.
    static func run(_ executable: URL,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    onStdoutLine: ((String) -> Void)? = nil,
                    onStderrLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                let outBuf = LockedData(), errBuf = LockedData()
                let outLines = LineSplitter(handler: onStdoutLine)
                let errLines = LineSplitter(handler: onStderrLine)

                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    outBuf.append(d); outLines.feed(d)
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    errBuf.append(d); errLines.feed(d)
                }

                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    outBuf.append(restOut); outLines.feed(restOut); outLines.flush()
                    errBuf.append(restErr); errLines.feed(restErr); errLines.flush()
                    cont.resume(returning: ProcessResult(
                        status: proc.terminationStatus,
                        stdout: outBuf.value,
                        stderr: String(data: errBuf.value, encoding: .utf8) ?? ""))
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Finds command-line tools installed via Homebrew/MacPorts/pip even when the app is launched from Finder
/// (GUI apps don't inherit the shell PATH).
enum ToolLocator {
    static let searchDirectories: [String] = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
                    (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        return dirs
    }()

    static func find(_ name: String) -> URL? {
        for dir in searchDirectories {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}
