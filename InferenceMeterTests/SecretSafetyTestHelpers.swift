import Darwin
import Foundation
import Testing
@testable import InferenceMeter

private let standardOutputCaptureGate = AsyncGate()

private actor AsyncGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

struct CapturedStandardOutput {
    var stdout: String
    var stderr: String

    var combined: String {
        stdout + stderr
    }
}

func captureStandardOutput(_ operation: () async throws -> Void) async throws -> CapturedStandardOutput {
    await standardOutputCaptureGate.wait()
    fflush(stdout)
    fflush(stderr)

    let originalStdout = dup(STDOUT_FILENO)
    let originalStderr = dup(STDERR_FILENO)
    precondition(originalStdout >= 0)
    precondition(originalStderr >= 0)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    do {
        try await operation()
    } catch {
        restoreStandardOutput(
            originalStdout: originalStdout,
            originalStderr: originalStderr,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        await standardOutputCaptureGate.signal()
        throw error
    }

    restoreStandardOutput(
        originalStdout: originalStdout,
        originalStderr: originalStderr,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe
    )
    await standardOutputCaptureGate.signal()

    return CapturedStandardOutput(
        stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

func expectNoSecretLeaks(
    output: CapturedStandardOutput,
    usages: [Usage],
    sentinels: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let surfaces = [output.stdout, output.stderr] + usages.flatMap { usage in
        [
            String(describing: usage),
            String(reflecting: usage)
        ]
    }

    for sentinel in sentinels {
        for surface in surfaces {
            #expect(!surface.contains(sentinel), "Leaked sentinel: \(sentinel)", sourceLocation: sourceLocation)
        }
    }
}

private func restoreStandardOutput(
    originalStdout: Int32,
    originalStderr: Int32,
    stdoutPipe: Pipe,
    stderrPipe: Pipe
) {
    fflush(stdout)
    fflush(stderr)
    dup2(originalStdout, STDOUT_FILENO)
    dup2(originalStderr, STDERR_FILENO)
    close(originalStdout)
    close(originalStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()
}
