import Foundation

public actor SessionStore {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func save(_ document: SessionDocument) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL(for: document.id), options: .atomic)
    }

    public func load(id: UUID) throws -> SessionDocument {
        let data = try Data(contentsOf: fileURL(for: id))
        return try decoder.decode(SessionDocument.self, from: data)
    }

    public func list() throws -> [SessionDocument] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionDocument.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        let document = try load(id: id)
        try FileManager.default.removeItem(at: fileURL(for: id))

        guard let audioFileName = document.audioFileName,
              URL(fileURLWithPath: audioFileName).lastPathComponent == audioFileName else {
            return
        }
        let audioURL = directoryURL.appendingPathComponent(audioFileName)
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
