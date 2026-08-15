import Foundation
import LingoSlateCore

struct SessionPracticeExportResult: Sendable {
    let directoryURL: URL
    let audioURL: URL?
    let englishSRTURL: URL
    let bilingualSRTURL: URL
    let transcriptURL: URL
}

enum SessionPracticeExporter {
    static func export(
        session: SessionDocument,
        sessionDirectoryURL: URL,
        destinationDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> SessionPracticeExportResult {
        let baseName = exportBaseName(for: session)
        let packageURL = uniqueDirectoryURL(
            named: "\(baseName)-听力练习",
            in: destinationDirectoryURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )

        do {
            let englishSRTURL = packageURL.appendingPathComponent("\(baseName)-English.srt")
            let bilingualSRTURL = packageURL.appendingPathComponent("\(baseName)-Bilingual.srt")
            let transcriptURL = packageURL.appendingPathComponent("\(baseName)-Bilingual.txt")

            try englishSRT(for: session).write(
                to: englishSRTURL,
                atomically: true,
                encoding: .utf8
            )
            try bilingualSRT(for: session).write(
                to: bilingualSRTURL,
                atomically: true,
                encoding: .utf8
            )
            try transcriptText(for: session).write(
                to: transcriptURL,
                atomically: true,
                encoding: .utf8
            )

            let audioURL = try copyAudioIfAvailable(
                for: session,
                baseName: baseName,
                sessionDirectoryURL: sessionDirectoryURL,
                packageURL: packageURL,
                fileManager: fileManager
            )
            return SessionPracticeExportResult(
                directoryURL: packageURL,
                audioURL: audioURL,
                englishSRTURL: englishSRTURL,
                bilingualSRTURL: bilingualSRTURL,
                transcriptURL: transcriptURL
            )
        } catch {
            try? fileManager.removeItem(at: packageURL)
            throw error
        }
    }

    static func englishSRT(for session: SessionDocument) -> String {
        srt(for: session) { segment in
            normalizedCaptionText(segment.sourceText)
        }
    }

    static func bilingualSRT(for session: SessionDocument) -> String {
        srt(for: session) { segment in
            let source = normalizedCaptionText(segment.sourceText)
            guard let translated = segment.translatedText,
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return source
            }
            return "\(source)\n\(normalizedCaptionText(translated))"
        }
    }

    static func transcriptText(for session: SessionDocument) -> String {
        let title = session.configuration.course.name.isEmpty
            ? (session.configuration.kind == .lecture ? "未命名课堂" : "未命名会议")
            : session.configuration.course.name
        var lines = [
            title,
            session.startedAt.formatted(date: .long, time: .shortened),
            "",
        ]
        for segment in eligibleSegments(in: session) {
            lines.append("[\(plainTimestamp(segment.startTime))] \(normalizedCaptionText(segment.sourceText))")
            if let translated = segment.translatedText,
               !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(normalizedCaptionText(translated))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func srt(
        for session: SessionDocument,
        text: (TranscriptSegment) -> String
    ) -> String {
        eligibleSegments(in: session).enumerated().map { index, segment in
            let endTime = max(segment.endTime, segment.startTime + 0.1)
            return """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(endTime))
            \(text(segment))
            """
        }
        .joined(separator: "\n\n")
        .appending("\n")
    }

    private static func eligibleSegments(in session: SessionDocument) -> [TranscriptSegment] {
        session.segments
            .filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                lhs.startTime == rhs.startTime
                    ? lhs.endTime < rhs.endTime
                    : lhs.startTime < rhs.startTime
            }
    }

    private static func copyAudioIfAvailable(
        for session: SessionDocument,
        baseName: String,
        sessionDirectoryURL: URL,
        packageURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        guard let audioFileName = session.audioFileName,
              URL(fileURLWithPath: audioFileName).lastPathComponent == audioFileName else {
            return nil
        }
        let sourceURL = sessionDirectoryURL.appendingPathComponent(audioFileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationURL = packageURL
            .appendingPathComponent("\(baseName)-Recording")
            .appendingPathExtension(pathExtension)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func exportBaseName(for session: SessionDocument) -> String {
        let rawTitle = session.configuration.course.name.isEmpty
            ? (session.configuration.kind == .lecture ? "Lecture" : "Meeting")
            : session.configuration.course.name
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let cleanedTitle = rawTitle
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safeTitle = String(cleanedTitle.prefix(80)).trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(safeTitle.isEmpty ? "Lecture" : safeTitle)-\(formatter.string(from: session.startedAt))"
    }

    private static func uniqueDirectoryURL(
        named name: String,
        in parentURL: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = parentURL.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentURL.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func normalizedCaptionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func srtTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, Int((time * 1_000).rounded()))
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            milliseconds / 60_000 % 60,
            milliseconds / 1_000 % 60,
            milliseconds % 1_000
        )
    }

    private static func plainTimestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return seconds >= 3_600
            ? String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
