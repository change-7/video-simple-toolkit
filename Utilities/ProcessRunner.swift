import Foundation
import Darwin

struct ProcessResult {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
}

final class RunningProcess {
    private let process: Process
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    init(process: Process, stdoutHandle: FileHandle, stderrHandle: FileHandle) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    func cancel() {
        guard process.isRunning else { return }
        if signalProcessGroup(SIGTERM) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.process.isRunning else { return }
                _ = self.signalProcessGroup(SIGKILL)
            }
            return
        }

        process.terminate()
    }

    func cancelGracefully() {
        guard process.isRunning else { return }

        if signalProcessGroup(SIGINT) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.process.isRunning else { return }
                _ = self.signalProcessGroup(SIGTERM)
            }
            return
        }

        process.interrupt()
    }

    @discardableResult
    func pause() -> Bool {
        guard process.isRunning else { return false }
        return signalProcessGroup(SIGSTOP)
    }

    @discardableResult
    func resume() -> Bool {
        guard process.isRunning else { return false }
        return signalProcessGroup(SIGCONT)
    }

    func cleanup() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
    }

    @discardableResult
    private func signalProcessGroup(_ signal: Int32) -> Bool {
        let pid = process.processIdentifier
        guard pid > 0 else { return false }

        if kill(-pid, signal) == 0 {
            return true
        }

        return kill(pid, signal) == 0
    }
}

private final class PipeLineReader {
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)

        let newLine = Data([0x0A])
        while let range = buffer.range(of: newLine) {
            var lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)

            if lineData.last == 0x0D {
                lineData.removeLast()
            }

            emit(lineData)
        }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        emit(buffer)
        buffer.removeAll(keepingCapacity: false)
    }

    private func emit(_ data: Data) {
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        onLine(text)
    }
}

enum ProcessRunner {
    static func runAndCapture(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> ProcessResult? {
        runAndCapture(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            environment: environment
        )
    }

    static func runAndCapture(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> ProcessResult? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let resultLock = NSLock()
        let readGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        do {
            try process.run()
        } catch {
            return nil
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            resultLock.lock()
            stdoutData = data
            resultLock.unlock()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            resultLock.lock()
            stderrData = data
            resultLock.unlock()
            readGroup.leave()
        }

        process.waitUntilExit()
        readGroup.wait()

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    @discardableResult
    static func runStreaming(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onStdoutLine: @escaping (String) -> Void,
        onStderrLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> RunningProcess {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutReader = PipeLineReader(onLine: onStdoutLine)
        let stderrReader = PipeLineReader(onLine: onStderrLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutReader.flush()
                return
            }
            stdoutReader.consume(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrReader.flush()
                return
            }
            stderrReader.consume(data)
        }

        process.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutReader.flush()
            stderrReader.flush()
            onExit(process.terminationStatus)
        }

        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        return RunningProcess(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading
        )
    }
}
