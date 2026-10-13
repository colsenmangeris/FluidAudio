import CoreML
import Foundation
import XCTest
@testable import FluidAudio

/// Opt-in tests use separately provisioned real CTC models and tokenizer assets.
/// No inference, downloads, microphone, preferences, or ordinary cache reads occur.
final class VocabularyCacheIsolationTests: XCTestCase {
    private func provisionedModelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLUIDAUDIO_CTC_TEST_MODELS_DIRECTORY"], !path.isEmpty
        else {
            throw XCTSkip("Set FLUIDAUDIO_CTC_TEST_MODELS_DIRECTORY to separately provisioned real CTC 110M assets.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudio-CTC-Cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testLoadsExplicitPrivateTokenizer() async throws {
        let modelDirectory = try provisionedModelDirectory()
        let models = try await CtcModels.load(from: modelDirectory, variant: .ctc110m)
        let directory = try privateDirectory()
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try FileManager.default.copyItem(
                at: modelDirectory.appendingPathComponent(name),
                to: directory.appendingPathComponent(name)
            )
        }
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let tokens = tokenizer.encode("SayStone")
        XCTAssertFalse(tokens.isEmpty)
        let vocabulary = CustomVocabularyContext(terms: [CustomVocabularyTerm(text: "SayStone", ctcTokenIds: tokens)])
        let manager = AsrManager()
        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary,
            ctcModels: models,
            config: .init(useAdaptiveThresholds: false, referenceTokenCount: 7),
            ctcModelDirectory: directory
        )
        let rescorer = await manager.vocabularyRescorer
        XCTAssertEqual(rescorer?.ctcTokenizer?.encode("SayStone"), tokens)
        XCTAssertEqual(rescorer?.config.referenceTokenCount, 7)
        XCTAssertEqual(rescorer?.config.useAdaptiveThresholds, false)
        let enabled = await manager.vocabBoostingEnabled
        XCTAssertTrue(enabled)
        await manager.disableVocabularyBoosting()
    }

    func testMissingPrivateTokenizerThrowsWithoutCacheFallback() async throws {
        let directory = try privateDirectory()
        let models = try await CtcModels.load(from: provisionedModelDirectory(), variant: .ctc110m)
        let manager = AsrManager()
        do {
            try await manager.configureVocabularyBoosting(
                vocabulary: .init(terms: [CustomVocabularyTerm(text: "authored")]),
                ctcModels: models,
                ctcModelDirectory: directory
            )
            XCTFail("Missing private assets must fail rather than borrowing a public tokenizer")
        } catch CtcTokenizer.Error.tokenizerNotFound(let failedDirectory) {
            XCTAssertEqual(failedDirectory, directory)
        }
        await manager.disableVocabularyBoosting()
        let enabled = await manager.vocabBoostingEnabled
        XCTAssertFalse(enabled)
    }

    // Compile the legacy call shape without executing its ordinary-cache read.
    private func legacyCaller(manager: AsrManager, vocabulary: CustomVocabularyContext, models: CtcModels) async throws
    {
        try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: models)
    }
}
