import Foundation
import LingoSlateCore
import XCTest
@testable import LingoSlateMac

final class SessionPracticeExporterTests: XCTestCase {
    func testExportCreatesAudioAndListeningPracticeTranscripts() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsURL = rootURL.appendingPathComponent("Sessions", isDirectory: true)
        let exportsURL = rootURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let audioURL = sessionsURL.appendingPathComponent("lesson.m4a")
        let audioData = Data("test audio".utf8)
        try audioData.write(to: audioURL)
        let session = makeSession(audioFileName: audioURL.lastPathComponent)

        let result = try SessionPracticeExporter.export(
            session: session,
            sessionDirectoryURL: sessionsURL,
            destinationDirectoryURL: exportsURL
        )

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.audioURL)), audioData)
        let englishSRT = try String(contentsOf: result.englishSRTURL, encoding: .utf8)
        XCTAssertTrue(englishSRT.contains("00:00:01,200 --> 00:00:03,450"))
        XCTAssertTrue(englishSRT.contains("Hello AWS."))
        XCTAssertFalse(englishSRT.contains("你好，AWS。"))

        let bilingualSRT = try String(contentsOf: result.bilingualSRTURL, encoding: .utf8)
        XCTAssertTrue(bilingualSRT.contains("Hello AWS.\n你好，AWS。"))
        XCTAssertTrue(bilingualSRT.contains("2\n00:01:05,000 --> 00:01:06,000"))

        let transcript = try String(contentsOf: result.transcriptURL, encoding: .utf8)
        XCTAssertTrue(transcript.contains("[00:01] Hello AWS."))
        XCTAssertTrue(transcript.contains("[01:05] Review the bucket policy."))
    }

    func testExportStillCreatesTranscriptsWhenAudioIsMissing() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsURL = rootURL.appendingPathComponent("Sessions", isDirectory: true)
        let exportsURL = rootURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let result = try SessionPracticeExporter.export(
            session: makeSession(audioFileName: "missing.m4a"),
            sessionDirectoryURL: sessionsURL,
            destinationDirectoryURL: exportsURL
        )

        XCTAssertNil(result.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.englishSRTURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bilingualSRTURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.transcriptURL.path))
    }

    private func makeSession(audioFileName: String?) -> SessionDocument {
        SessionDocument(
            configuration: SessionConfiguration(
                course: Course(name: "Cloud / Security"),
                kind: .lecture
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_070),
            segments: [
                TranscriptSegment(
                    startTime: 1.2,
                    endTime: 3.45,
                    sourceText: "Hello AWS.",
                    translatedText: "你好，AWS。",
                    state: .translated,
                    provider: "test"
                ),
                TranscriptSegment(
                    startTime: 65,
                    endTime: 66,
                    sourceText: "Review the bucket policy.",
                    state: .final,
                    provider: "test"
                ),
            ],
            audioFileName: audioFileName
        )
    }
}
