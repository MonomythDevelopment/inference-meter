import Darwin
import Foundation

struct CodexAppServerClient: Sendable {
    private let fetchRateLimitsData: @Sendable () async -> Data?

    init(fetchRateLimitsData: @escaping @Sendable () async -> Data?) {
        self.fetchRateLimitsData = fetchRateLimitsData
    }

    func fetchRateLimits() async -> Data? {
        await fetchRateLimitsData()
    }
}

extension CodexAppServerClient {
    static func live(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexAppServerClient? {
        guard let executableURL = codexExecutableURL(
            homeDirectory: homeDirectory,
            environment: environment
        ) else {
            return nil
        }

        return CodexAppServerClient {
            await Task.detached(priority: .utility) {
                fetchRateLimits(executableURL: executableURL)
            }.value
        }
    }
}

private extension CodexAppServerClient {
    static let responseID = 2
    static let timeoutMilliseconds: Int32 = 10_000
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    static func codexExecutableURL(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL? {
        let codexHome = environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        var candidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex", isDirectory: false),
            codexHome.appendingPathComponent("packages/standalone/current/bin/codex", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/codex", isDirectory: false)
        ]

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { directory in
                URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            })
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func fetchRateLimits(executableURL: URL) -> Data? {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        defer {
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForReading.close()

            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        do {
            try standardInput.fileHandleForWriting.write(contentsOf: requestData())
        } catch {
            return nil
        }

        let outputHandle = standardOutput.fileHandleForReading
        var descriptor = pollfd(
            fd: outputHandle.fileDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        var bufferedData = Data()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutMilliseconds)))

        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let remainingMilliseconds = max(
                1,
                min(
                    Int(timeoutMilliseconds),
                    Int(remaining.components.seconds * 1_000)
                        + Int(remaining.components.attoseconds / 1_000_000_000_000_000)
                )
            )
            descriptor.revents = 0

            guard poll(&descriptor, 1, Int32(remainingMilliseconds)) > 0 else {
                continue
            }

            let chunk = outputHandle.availableData
            guard !chunk.isEmpty else {
                return nil
            }

            bufferedData.append(chunk)
            guard bufferedData.count <= maximumResponseBytes else {
                return nil
            }

            while let newlineIndex = bufferedData.firstIndex(of: 10) {
                let line = Data(bufferedData[..<newlineIndex])
                bufferedData.removeSubrange(...newlineIndex)

                if isRateLimitsResponse(line) {
                    return line
                }
            }
        }

        return nil
    }

    static func requestData() -> Data {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let messages = [
            #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"inference_meter","title":"Inference Meter","version":"\#(version)"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2}"#
        ]

        return Data((messages.joined(separator: "\n") + "\n").utf8)
    }

    static func isRateLimitsResponse(_ data: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(CodexAppServerResponseIdentifier.self, from: data) else {
            return false
        }

        return response.id == responseID && response.result != nil
    }
}

private struct CodexAppServerResponseIdentifier: Decodable {
    var id: Int?
    var result: EmptyCodable?
}

private struct EmptyCodable: Decodable {}
