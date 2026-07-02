import Foundation

struct FileReader: Sendable {
    private let readDataHandler: @Sendable (URL) throws -> Data

    init(readData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        readDataHandler = readData
    }

    func data(contentsOf url: URL) throws -> Data {
        try readDataHandler(url)
    }
}
