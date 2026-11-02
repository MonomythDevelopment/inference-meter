import Foundation
import Security

enum KeychainError: Error, Equatable, Sendable {
    case itemNotFound
    case unexpectedItemData
    case unhandled(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound:
            self = .itemNotFound
        default:
            self = .unhandled(status)
        }
    }
}

struct Keychain: Sendable {
    private let readGenericPasswordHandler: @Sendable (_ service: String, _ account: String) throws -> Data

    init(
        readGenericPassword: @escaping @Sendable (_ service: String, _ account: String) throws -> Data = Keychain.securityToolReadGenericPassword
    ) {
        readGenericPasswordHandler = readGenericPassword
    }

    func readGenericPassword(service: String, account: String) throws -> Data {
        try readGenericPasswordHandler(service, account)
    }
}

private extension Keychain {
    static let securityToolURL = URL(fileURLWithPath: "/usr/bin/security")
    static let securityToolTimeout = DispatchTimeInterval.seconds(5)
    // The tool exits with the low byte of its OSStatus; 44 is errSecItemNotFound.
    static let securityToolItemNotFoundExitStatus: Int32 = 44

    // Claude Code writes and reads its credential through /usr/bin/security, so that tool is
    // always trusted on the item and the partition list holds only "apple-tool:". Reading with
    // SecItemCopyMatching fails that partition check, and macOS asks for the login password
    // however many times "Always Allow" was chosen. Reading the same way the owner does never
    // prompts. The credential travels over a pipe; only the service and account are arguments.
    static func securityToolReadGenericPassword(service: String, account: String) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = securityToolURL
        process.arguments = ["find-generic-password", "-a", account, "-w", "-s", service]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let processIdentifier = process.processIdentifier
        // SIGKILL because a child ignoring SIGTERM would keep the pipe open and block the read.
        let timeout = DispatchWorkItem { kill(processIdentifier, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + securityToolTimeout, execute: timeout)
        defer { timeout.cancel() }

        let output = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw process.terminationStatus == securityToolItemNotFoundExitStatus
                ? KeychainError.itemNotFound
                : KeychainError.unhandled(process.terminationStatus)
        }

        // The tool terminates the password with a newline that is not part of the item.
        let data = output.last == UInt8(ascii: "\n") ? output.dropLast() : output[...]

        guard !data.isEmpty else {
            throw KeychainError.unexpectedItemData
        }

        return Data(data)
    }
}
