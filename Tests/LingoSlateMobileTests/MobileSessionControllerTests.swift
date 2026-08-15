import Foundation
import LingoSlateCore
@testable import LingoSlateMobile
import XCTest

@MainActor
final class MobileSessionControllerTests: XCTestCase {
    func testStartsSonioxWithChineseTranslationAndPublishesBilingualCaption() async throws {
        let capture = TestCapture(permissionGranted: true)
        let recognition = TestRecognition()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MobileSessionController(
            apiKeyProvider: { "test-key" },
            sessionDirectoryURL: directory,
            captureFactory: { _ in capture },
            recognitionFactory: { _ in recognition }
        )

        await controller.start(courseName: "Cloud Computing")
        try await Task.sleep(for: .milliseconds(100))

        let configuration = await recognition.configuration
        XCTAssertEqual(configuration?.translationTargetLanguage, "zh")
        XCTAssertEqual(configuration?.course.name, "Cloud Computing")
        XCTAssertEqual(controller.snapshot.finalSegments.first?.sourceText, "The lecture starts now.")
        XCTAssertEqual(controller.snapshot.finalSegments.first?.translatedText, "课程现在开始。")
        XCTAssertEqual(controller.state, .listening)
    }

    func testDeniedMicrophoneDoesNotStartRecognition() async {
        let capture = TestCapture(permissionGranted: false)
        let recognition = TestRecognition()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MobileSessionController(
            apiKeyProvider: { "test-key" },
            sessionDirectoryURL: directory,
            captureFactory: { _ in capture },
            recognitionFactory: { _ in recognition }
        )

        await controller.start()

        let configuration = await recognition.configuration
        XCTAssertNil(configuration)
        guard case .failed = controller.state else {
            return XCTFail("Expected permission failure")
        }
    }

    func testStopWhilePreparingCancelsBeforeRecognitionStarts() async throws {
        let capture = TestCapture(permissionGranted: true)
        let recognition = TestRecognition()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MobileSessionController(
            apiKeyProvider: {
                try await Task.sleep(for: .milliseconds(100))
                return "test-key"
            },
            sessionDirectoryURL: directory,
            captureFactory: { _ in capture },
            recognitionFactory: { _ in recognition }
        )

        let startTask = Task { await controller.start() }
        try await Task.sleep(for: .milliseconds(10))
        await controller.stop()
        await startTask.value

        let configuration = await recognition.configuration
        XCTAssertNil(configuration)
        XCTAssertEqual(controller.state, .idle)
    }

    func testStopPersistsBilingualTranscriptAndAudioReference() async throws {
        let capture = TestCapture(permissionGranted: true)
        let recognition = TestRecognition()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MobileSessionController(
            apiKeyProvider: { "test-key" },
            sessionDirectoryURL: directory,
            captureFactory: { _ in capture },
            recognitionFactory: { _ in recognition }
        )

        await controller.start(courseName: "Cloud Computing")
        try await Task.sleep(for: .milliseconds(50))
        controller.addMarker(.important)
        await controller.stop()
        try await Task.sleep(for: .milliseconds(50))

        let documents = try await SessionStore(directoryURL: directory).list()
        let document = try XCTUnwrap(documents.first)
        XCTAssertNotNil(document.endedAt)
        XCTAssertEqual(document.configuration.processingMode, .soniox)
        XCTAssertEqual(document.segments.first?.sourceText, "The lecture starts now.")
        XCTAssertEqual(document.segments.first?.translatedText, "课程现在开始。")
        XCTAssertEqual(document.audioFileName, "\(document.id.uuidString).m4a")
        XCTAssertEqual(document.markers.map(\.kind), [.important])
        XCTAssertEqual(document.summary?.overview, ["课程现在开始。"])
        XCTAssertEqual(document.isPostProcessingComplete, true)
    }

    func testCourseAndRegionalContextReachSoniox() async throws {
        let capture = TestCapture(permissionGranted: true)
        let recognition = TestRecognition()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MobileSessionController(
            apiKeyProvider: { "test-key" },
            sessionDirectoryURL: directory,
            captureFactory: { _ in capture },
            recognitionFactory: { _ in recognition }
        )
        let course = Course(
            name: "Cloud Computing",
            code: "COMPX500",
            roughDescription: "AWS security and architecture",
            lecturerNames: ["Dr Singh"],
            lecturerAccent: .indianEnglish,
            recognitionTerms: ["NIST"]
        )

        await controller.start(
            course: course,
            profile: UserProfile(schoolName: "University of Waikato", regionCode: "NZ")
        )

        let receivedConfiguration = await recognition.configuration
        let configuration = try XCTUnwrap(receivedConfiguration)
        XCTAssertEqual(configuration.course.code, "COMPX500")
        XCTAssertEqual(configuration.course.lecturerAccent, .indianEnglish)
        XCTAssertTrue(configuration.approvedTerms.contains { $0.source == "MyWaikato" })
        XCTAssertTrue(configuration.approvedTerms.contains { $0.source == "NIST" })
        XCTAssertEqual(configuration.translationTargetLanguage, "zh")
    }

    func testTemporaryKeyProviderSendsBrokerAuthorization() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer broker-secret"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(#"{"api_key":"temp:test","expires_at":"2026-07-22T07:00:00Z"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let provider = MobileAPIKeyProvider.temporaryKey(
            endpoint: URL(string: "https://broker.example/v1/soniox/temporary-key")!,
            bearerToken: "broker-secret",
            session: URLSession(configuration: configuration)
        )

        let key = try await provider()
        XCTAssertEqual(key, "temp:test")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateMobileTests-\(UUID().uuidString)")
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data) = Self.handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor TestCapture: AudioCaptureEngine {
    nonisolated let events: AsyncStream<AudioCaptureEvent>
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let permissionGranted: Bool

    init(permissionGranted: Bool) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.permissionGranted = permissionGranted
    }

    func requestPermission() async -> Bool { permissionGranted }

    func start() async throws {
        continuation.yield(.started(sampleRate: 16_000))
    }

    func stop() async {
        continuation.yield(.stopped)
        continuation.finish()
    }
}

private actor TestRecognition: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private(set) var configuration: RecognitionConfiguration?

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        self.configuration = configuration
        continuation.yield(.started)
        continuation.yield(
            .bilingualFinal(
                BilingualRecognitionResult(
                    id: UUID(),
                    sourceText: "The lecture starts now.",
                    translatedText: "课程现在开始。",
                    sourceLanguage: "en",
                    startTime: 0,
                    endTime: 2,
                    recognitionProvider: "soniox",
                    translationProvider: "soniox"
                )
            )
        )
    }

    func accept(_ frame: AudioFrame) async throws {}

    func finalize() async throws {
        continuation.yield(.finished)
        continuation.finish()
    }
}
