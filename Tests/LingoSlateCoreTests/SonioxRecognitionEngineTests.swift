import LingoSlateCore
import XCTest
@testable import LingoSlateSoniox

final class SonioxRecognitionEngineTests: XCTestCase {
    func testStartRequestIncludesCourseContextWithoutTranslation() throws {
        let data = try SonioxStartRequestBuilder.make(
            apiKey: "secret",
            configuration: RecognitionConfiguration(
                course: Course(
                    name: "Mobile Computing",
                    lecturerNames: ["Dr Singh"],
                    lecturerAccent: .indianEnglish,
                    recognitionTerms: ["Kotlin", "Jetpack Compose"]
                ),
                approvedTerms: [
                    GlossaryTerm(
                        source: "LLM",
                        target: "大语言模型",
                        aliases: ["LLMs"],
                        origin: .user,
                        isApproved: true
                    ),
                ]
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        let terms = try XCTUnwrap(context["terms"] as? [String])

        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["language_hints"] as? [String], ["en", "zh"])
        XCTAssertEqual(object["language_hints_strict"] as? Bool, true)
        XCTAssertNil(object["translation"])
        XCTAssertTrue(terms.contains("Kotlin"))
        XCTAssertTrue(terms.contains("LLMs"))
    }

    func testStartRequestEnablesOneWayTranslationAndApprovedTerms() throws {
        let data = try SonioxStartRequestBuilder.make(
            apiKey: "secret",
            configuration: RecognitionConfiguration(
                course: Course(name: "Cloud Computing"),
                approvedTerms: [
                    GlossaryTerm(
                        source: "IaaS",
                        target: "基础设施即服务",
                        aliases: ["Infrastructure as a Service"],
                        origin: .user,
                        isApproved: true
                    ),
                ],
                translationTargetLanguage: "zh"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let translation = try XCTUnwrap(object["translation"] as? [String: String])
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        let translationTerms = try XCTUnwrap(
            context["translation_terms"] as? [[String: String]]
        )

        XCTAssertEqual(translation["type"], "one_way")
        XCTAssertEqual(translation["target_language"], "zh")
        XCTAssertEqual(object["endpoint_latency_adjustment_level"] as? Int, 1)
        XCTAssertEqual(object["endpoint_sensitivity"] as? Double, 0)
        XCTAssertEqual(object["max_endpoint_delay_ms"] as? Int, 1_000)
        XCTAssertTrue(
            translationTerms.contains([
                "source": "IaaS",
                "target": "基础设施即服务",
            ])
        )
        XCTAssertTrue(
            translationTerms.contains([
                "source": "Infrastructure as a Service",
                "target": "基础设施即服务",
            ])
        )
    }

    func testStartRequestExcludesAmbiguousCloudTrailRecognitionHint() throws {
        let data = try SonioxStartRequestBuilder.make(
            apiKey: "secret",
            configuration: RecognitionConfiguration(
                course: Course(
                    name: "Secure Cloud Application Engineering",
                    recognitionTerms: ["NIST", "CloudTrail"]
                )
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        let terms = try XCTUnwrap(context["terms"] as? [String])

        XCTAssertTrue(terms.contains("NIST"))
        XCTAssertFalse(terms.contains("CloudTrail"))
        XCTAssertFalse(terms.contains("AWS CloudTrail"))
    }

    func testAssemblerUsesEndpointAsFinalUtteranceBoundary() throws {
        var assembler = SonioxUtteranceAssembler()
        let provisional = assembler.consume(
            SonioxResponse(
                tokens: [
                    token("We use", start: 100, end: 400, isFinal: false),
                    token(" Kotlin", start: 400, end: 700, isFinal: false),
                ],
                totalAudioProcessedMilliseconds: 800
            )
        )
        guard case let .provisional(id, text, start, end, provider) = provisional.first else {
            return XCTFail("Expected provisional utterance")
        }
        XCTAssertEqual(text, "We use Kotlin")
        XCTAssertEqual(start, 0.1, accuracy: 0.001)
        XCTAssertEqual(end, 0.7, accuracy: 0.001)
        XCTAssertEqual(provider, "soniox-stt-rt-v5")

        let finalized = assembler.consume(
            SonioxResponse(
                tokens: [
                    token("We use", start: 100, end: 400, isFinal: true, speaker: "1"),
                    token(" Kotlin", start: 400, end: 700, isFinal: true, speaker: "1"),
                    token("<end>", isFinal: true),
                ],
                finalAudioProcessedMilliseconds: 700,
                totalAudioProcessedMilliseconds: 800
            )
        )
        guard case let .final(finalID, finalText, _, _, speaker, finalProvider) = finalized.first else {
            return XCTFail("Expected final utterance")
        }
        XCTAssertEqual(finalID, id)
        XCTAssertEqual(finalText, "We use Kotlin")
        XCTAssertEqual(speaker, "1")
        XCTAssertEqual(finalProvider, "soniox-stt-rt-v5")
    }

    func testAssemblerPreservesChineseForPipelineExclusion() {
        var assembler = SonioxUtteranceAssembler()
        let events = assembler.consume(
            SonioxResponse(
                tokens: [
                    token("这个", start: 0, end: 300, isFinal: true, language: "zh"),
                    token("怎么做？", start: 300, end: 700, isFinal: true, language: "zh"),
                    token("<end>", isFinal: true),
                ]
            )
        )
        guard case let .final(_, text, _, _, _, _) = events.first else {
            return XCTFail("Expected Chinese final utterance")
        }
        XCTAssertEqual(text, "这个怎么做？")
    }

    func testAssemblerSeparatesOriginalAndTranslatedTokens() {
        var assembler = SonioxUtteranceAssembler(expectsTranslation: true)
        let events = assembler.consume(
            SonioxResponse(
                tokens: [
                    token(
                        "The assignment",
                        start: 100,
                        end: 700,
                        isFinal: true,
                        speaker: "1",
                        language: "en",
                        translationStatus: "original"
                    ),
                    token(
                        " is due Friday.",
                        start: 700,
                        end: 1_200,
                        isFinal: true,
                        speaker: "1",
                        language: "en",
                        translationStatus: "original"
                    ),
                    token(
                        "作业周五截止。",
                        isFinal: false,
                        language: "zh",
                        translationStatus: "translation",
                        sourceLanguage: "en"
                    ),
                    token("<end>", isFinal: true),
                ]
            )
        )

        guard case let .bilingualFinal(result) = events.first else {
            return XCTFail("Expected bilingual final utterance")
        }
        XCTAssertEqual(result.sourceText, "The assignment is due Friday.")
        XCTAssertEqual(result.translatedText, "作业周五截止。")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.speaker, "1")
        XCTAssertEqual(result.startTime, 0.1, accuracy: 0.001)
        XCTAssertEqual(result.endTime, 1.2, accuracy: 0.001)
        XCTAssertEqual(result.translationProvider, "soniox-translation-stt-rt-v5")
    }

    func testAssemblerSoftCommitsLongStableBilingualSentenceWithoutEndpoint() {
        var assembler = SonioxUtteranceAssembler(expectsTranslation: true)
        let events = assembler.consume(
            SonioxResponse(
                tokens: [
                    token(
                        "Cloud auditors generate a report.",
                        start: 100,
                        end: 12_600,
                        isFinal: true,
                        language: "en",
                        translationStatus: "original"
                    ),
                    token(
                        "云服务审计方会生成报告。",
                        isFinal: true,
                        language: "zh",
                        translationStatus: "translation",
                        sourceLanguage: "en"
                    ),
                ],
                totalAudioProcessedMilliseconds: 12_800
            )
        )

        guard case let .bilingualFinal(result) = events.first else {
            return XCTFail("Expected a stable sentence soft commit")
        }
        XCTAssertEqual(result.sourceText, "Cloud auditors generate a report.")
        XCTAssertEqual(result.translatedText, "云服务审计方会生成报告。")
        XCTAssertEqual(result.startTime, 0.1, accuracy: 0.001)
        XCTAssertEqual(result.endTime, 12.6, accuracy: 0.001)
    }

    func testAssemblerKeepsShortBilingualSentenceProvisionalUntilEndpoint() {
        var assembler = SonioxUtteranceAssembler(expectsTranslation: true)
        let provisional = assembler.consume(
            SonioxResponse(
                tokens: [
                    token(
                        "Right.",
                        start: 100,
                        end: 900,
                        isFinal: true,
                        language: "en",
                        translationStatus: "original"
                    ),
                    token(
                        "对。",
                        isFinal: true,
                        language: "zh",
                        translationStatus: "translation",
                        sourceLanguage: "en"
                    ),
                ]
            )
        )
        guard case .bilingualProvisional = provisional.first else {
            return XCTFail("Expected a short sentence to remain provisional")
        }

        let finalized = assembler.consume(
            SonioxResponse(tokens: [token("<end>", isFinal: true)])
        )
        guard case let .bilingualFinal(result) = finalized.first else {
            return XCTFail("Expected endpoint to finalize the short sentence")
        }
        XCTAssertEqual(result.sourceText, "Right.")
        XCTAssertEqual(result.translatedText, "对。")
    }

    func testErrorResponseDecodesServerDetails() throws {
        let data = Data(
            #"{"tokens":[],"error_code":402,"error_type":"organization_balance_exhausted","error_message":"Organization balance exhausted."}"#.utf8
        )

        let response = try JSONDecoder().decode(SonioxResponse.self, from: data)

        XCTAssertEqual(response.errorType, "organization_balance_exhausted")
        XCTAssertEqual(response.errorMessage, "Organization balance exhausted.")
    }

    func testAudioBatcherPreservesOrderAndFlushesTail() throws {
        var batcher = SonioxAudioBatcher(targetSampleCount: 4)

        XCTAssertTrue(batcher.append([0, 1, 2]).isEmpty)
        XCTAssertEqual(batcher.append([3, 4, 5, 6, 7, 8]), [
            [0, 1, 2, 3],
            [4, 5, 6, 7],
        ])
        XCTAssertEqual(try XCTUnwrap(batcher.finish()), [8])
        XCTAssertNil(batcher.finish())
    }

    func testReconnectPolicyRetriesOnlyRecoverableFailures() {
        XCTAssertTrue(SonioxReconnectPolicy.shouldReconnect(errorType: "service_unavailable"))
        XCTAssertTrue(SonioxReconnectPolicy.shouldReconnect(errorType: "request_timeout"))
        XCTAssertTrue(SonioxReconnectPolicy.shouldReconnect(errorType: "max_duration_reached"))
        XCTAssertFalse(SonioxReconnectPolicy.shouldReconnect(errorType: "unauthenticated"))
        XCTAssertFalse(
            SonioxReconnectPolicy.shouldReconnect(
                errorType: "organization_balance_exhausted"
            )
        )
        XCTAssertEqual(
            (1...4).map(SonioxReconnectPolicy.delayMilliseconds(forAttempt:)),
            [1_000, 2_000, 4_000, 4_000]
        )
    }

    func testAssemblerKeepsTimelineContinuousAfterReconnect() throws {
        var assembler = SonioxUtteranceAssembler(timeOffset: 1_320)
        let events = assembler.consume(
            SonioxResponse(
                tokens: [
                    token("Continue", start: 100, end: 500, isFinal: true),
                    token(" safely.", start: 500, end: 900, isFinal: true),
                    token("<end>", isFinal: true),
                ],
                totalAudioProcessedMilliseconds: 900
            )
        )

        guard case let .final(_, _, start, end, _, _) = events.first else {
            return XCTFail("Expected final utterance")
        }
        XCTAssertEqual(start, 1_320.1, accuracy: 0.001)
        XCTAssertEqual(end, 1_320.9, accuracy: 0.001)
    }

    private func token(
        _ text: String,
        start: Double? = nil,
        end: Double? = nil,
        isFinal: Bool,
        speaker: String? = nil,
        language: String? = nil,
        translationStatus: String? = nil,
        sourceLanguage: String? = nil
    ) -> SonioxToken {
        SonioxToken(
            text: text,
            startMilliseconds: start,
            endMilliseconds: end,
            isFinal: isFinal,
            speaker: speaker,
            language: language,
            translationStatus: translationStatus,
            sourceLanguage: sourceLanguage
        )
    }
}
