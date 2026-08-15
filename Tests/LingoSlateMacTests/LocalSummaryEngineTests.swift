import AppKit
import LingoSlateCore
import SwiftUI
import XCTest
@testable import LingoSlateMac

final class LocalSummaryEngineTests: XCTestCase {
    func testSummaryPromptSamplesTheWholeSessionAndIncludesMarkers() {
        let segments = (0..<100).map { index in
            TranscriptSegment(
                startTime: Double(index * 10),
                endTime: Double(index * 10 + 5),
                sourceText: "Segment \(index)",
                translatedText: "第 \(index) 段",
                state: .translated,
                provider: "test"
            )
        }
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Long Lecture")),
            segments: segments,
            markers: [SessionMarker(timestamp: 90, kind: .actionItem)]
        )

        let prompt = SummaryPromptBuilder.prompt(
            for: document,
            maximumCharacters: 10_000,
            maximumSegments: 5
        )

        XCTAssertTrue(prompt.contains("Segment 0"))
        XCTAssertTrue(prompt.contains("Segment 99"))
        XCTAssertTrue(prompt.contains("MARKER actionItem [01:30]"))
    }

    @MainActor
    func testSummaryViewRendersAtMinimumWorkspaceWidth() throws {
        let summary = SessionSummary(
            overview: [
                "本节课介绍了移动计算系统如何在网络变化时保持任务连续性。",
                "重点比较了事件驱动架构、后台任务和状态恢复策略。",
            ],
            keyConcepts: [
                "Mobile Computing",
                "Event Loop",
                "State Restoration",
            ],
            actionItems: [
                "[42:15] 请在下周五之前提交架构设计作业，并在报告中说明离线同步策略。",
            ]
        )
        let renderer = ImageRenderer(
            content: SummaryContentView(summary: summary)
                .frame(width: 860, height: 480)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )

        XCTAssertEqual(image.size.width, 860, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 480, accuracy: 0.5)
        XCTAssertGreaterThan(pngData.count, 10_000)

        let environment = ProcessInfo.processInfo.environment
        if let outputPath = environment["LINGOSLATE_SUMMARY_SNAPSHOT"]
            ?? environment["LECCUE_SUMMARY_SNAPSHOT"] {
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    @MainActor
    func testWorkspaceRendersAtCompactWidth() throws {
        let suiteName = "LingoSlateWorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = UserProfileStore(
            defaults: defaults,
            storageKey: "test.profile",
            legacyStorageKeys: [],
            legacyBundleIdentifiers: [],
            defaultRegionCode: "NZ"
        )
        let renderer = ImageRenderer(
            content: ClassroomWorkspaceView(
                profileStore: profileStore,
                sonioxCredentialStore: SonioxCredentialStore()
            )
            .frame(width: 760, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )

        XCTAssertEqual(image.size.width, 760, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 520, accuracy: 0.5)
        XCTAssertGreaterThan(pngData.count, 10_000)

        if let outputPath = ProcessInfo.processInfo.environment["LINGOSLATE_WORKSPACE_SNAPSHOT"] {
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}
