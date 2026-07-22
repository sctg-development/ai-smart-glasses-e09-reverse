/*
 * MIT License
 *
 * Copyright (c) 2026 Ronan Le Meillat - SCTG Development
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import XCTest

@testable import e09_reverse

// MARK: - Mistral AI Tests

class MistralAITests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testConfigInitialization() {
        let config1 = MistralAI.Config(apiKey: "test-key")
        XCTAssertEqual(config1.apiKey, "test-key")
        XCTAssertEqual(config1.baseURL, "https://api.mistral.ai/v1")
        XCTAssertEqual(config1.sttLanguage, "fr")
        XCTAssertEqual(config1.sttModel, "voxtral-mini-latest")  // Default STT model
        XCTAssertEqual(config1.ttsModel, "voxtral-mini-tts-latest")
        XCTAssertEqual(config1.ttsVoiceID, "49d024dd-981b-4462-bb17-74d381eb8fd7")
        XCTAssertEqual(config1.ttsOutputFormat, "mp3")
    }
    
    func testConfigWithCustomValues() {
        let config = MistralAI.Config(
            apiKey: "custom-key",
            baseURL: "https://custom.api.com/v1",
            sttLanguage: "en",
            sttModel: "custom-stt-model",
            ttsModel: "custom-tts-model",
            ttsVoiceID: "custom-voice-id",
            ttsOutputFormat: "wav"
        )
        
        XCTAssertEqual(config.apiKey, "custom-key")
        XCTAssertEqual(config.baseURL, "https://custom.api.com/v1")
        XCTAssertEqual(config.sttLanguage, "en")
        XCTAssertEqual(config.sttModel, "custom-stt-model")
        XCTAssertEqual(config.ttsModel, "custom-tts-model")
        XCTAssertEqual(config.ttsVoiceID, "custom-voice-id")
        XCTAssertEqual(config.ttsOutputFormat, "wav")
    }
    
    // MARK: - Initialization Tests
    
    func testInitializationWithValidAPIKey() {
        do {
            let mistral = try MistralAI(apiKey: "test-api-key")
            XCTAssertNotNil(mistral)
            XCTAssertEqual(mistral.currentConfig.apiKey, "test-api-key")
        } catch {
            XCTFail("Should not throw error with valid API key: \(error)")
        }
    }
    
    func testInitializationWithEmptyAPIKey() {
        XCTAssertThrowsError(try MistralAI(apiKey: "")) { error in
            if case MistralAI.MistralError.missingAPIKey = error {
                // Expected error
            } else {
                XCTFail("Expected missingAPIKey error, got: \(error)")
            }
        }
    }
    
    func testInitializationWithConfig() {
        do {
            let config = MistralAI.Config(
                apiKey: "config-api-key",
                sttLanguage: "de",
                ttsVoiceID: "custom-voice"
            )
            let mistral = try MistralAI(config: config)
            XCTAssertNotNil(mistral)
            XCTAssertEqual(mistral.currentConfig.apiKey, "config-api-key")
            XCTAssertEqual(mistral.currentConfig.sttLanguage, "de")
            XCTAssertEqual(mistral.currentConfig.ttsVoiceID, "custom-voice")
        } catch {
            XCTFail("Should not throw error with valid config: \(error)")
        }
    }
    
    // MARK: - Voice Structure Tests
    
    func testVoiceStructure() {
        let voice = MistralAI.Voice(
            id: "test-id",
            name: "Test Voice",
            slug: "test_voice",
            languages: ["fr_fr", "en_us"],
            gender: "female",
            age: 30,
            tags: ["neutral", "clear"],
            color: "#77778B",
            description: "A test voice",
            appearance: nil,
            retention_notice: 30,
            created_at: "2026-01-01T00:00:00Z",
            user_id: nil,
            trimmed_seconds: nil
        )
        
        XCTAssertEqual(voice.id, "test-id")
        XCTAssertEqual(voice.name, "Test Voice")
        XCTAssertEqual(voice.slug, "test_voice")
        XCTAssertEqual(voice.languages, ["fr_fr", "en_us"])
        XCTAssertEqual(voice.gender, "female")
        XCTAssertEqual(voice.age, 30)
        XCTAssertEqual(voice.tags, ["neutral", "clear"])
        XCTAssertEqual(voice.color, "#77778B")
        XCTAssertEqual(voice.description, "A test voice")
        XCTAssertEqual(voice.retention_notice, 30)
    }
    
    func testVoiceCodable() {
        let json = """
        {
            "id": "test-id",
            "name": "Test Voice",
            "slug": "test_voice",
            "languages": ["fr_fr"],
            "gender": "female",
            "age": 30,
            "tags": ["neutral"],
            "color": "#77778B",
            "description": "A test voice",
            "appearance": null,
            "retention_notice": 30,
            "created_at": "2026-01-01T00:00:00Z",
            "user_id": null,
            "trimmed_seconds": null
        }
        """
        
        let data = json.data(using: .utf8)!
        do {
            let voice = try JSONDecoder().decode(MistralAI.Voice.self, from: data)
            XCTAssertEqual(voice.id, "test-id")
            XCTAssertEqual(voice.name, "Test Voice")
            XCTAssertEqual(voice.languages, ["fr_fr"])
        } catch {
            XCTFail("Failed to decode Voice: \(error)")
        }
    }
    
    // MARK: - Error Tests
    
    func testErrorDescriptions() {
        let errors: [MistralAI.MistralError] = [
            .invalidAPIKey,
            .missingAPIKey,
            .invalidAudioFile,
            .invalidTextInput,
            .rateLimitExceeded,
            .serverError(statusCode: 500, message: "Internal Server Error"),
            .networkError(URLError(.notConnectedToInternet)),
            .decodingError(DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Test"))),
            .unsupportedFormat,
            .unknownError("Test error")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
        }
    }
    
    // MARK: - Utility Methods Tests
    
    func testGetAvailableVoices() {
        let voices = MistralAI.getAvailableVoices()
        
        XCTAssertNotNil(voices)
        XCTAssertTrue(voices.count > 0, "Should have at least one language")
        
        // Check French voices
        if let frenchVoices = voices["fr"] {
            XCTAssertTrue(frenchVoices.count >= 2, "Should have at least 2 French voices")
            XCTAssertEqual(frenchVoices["fr_marie_neutral"], "49d024dd-981b-4462-bb17-74d381eb8fd7")
        } else {
            XCTFail("Should have French voices")
        }
    }
    
    func testGetAvailableModels() {
        let models = MistralAI.getAvailableModels()
        
        XCTAssertNotNil(models)
        XCTAssertTrue(models.count == 2, "Should have STT and TTS models")
        
        // Check STT models
        if let sttModels = models["stt"] {
            XCTAssertTrue(sttModels.contains("voxtral-mini-latest"), "Should contain voxtral-mini-latest")
        } else {
            XCTFail("Should have STT models")
        }
        
        // Check TTS models
        if let ttsModels = models["tts"] {
            XCTAssertTrue(ttsModels.contains("voxtral-mini-tts-latest"), "Should contain voxtral-mini-tts-latest")
        } else {
            XCTFail("Should have TTS models")
        }
    }
    
    // MARK: - Convenience Methods Tests
    
    func testConvenienceTranscribeMethod() {
        do {
            let mistral = try MistralAI(apiKey: "test-key")
            XCTAssertNotNil(mistral)
        } catch {
            XCTFail("Should not throw error: \(error)")
        }
    }
    
    func testConvenienceSynthesizeMethod() {
        do {
            let mistral = try MistralAI(apiKey: "test-key")
            XCTAssertNotNil(mistral)
        } catch {
            XCTFail("Should not throw error: \(error)")
        }
    }
    
    // MARK: - Voice Filtering Tests
    
    func testVoiceFilteringByLanguage() {
        // Test the filtering logic (without actual API call)
        let testVoices = [
            MistralAI.Voice(id: "1", name: "French Voice", slug: "fr_voice", languages: ["fr_fr"]),
            MistralAI.Voice(id: "2", name: "English US Voice", slug: "en_us_voice", languages: ["en_us"]),
            MistralAI.Voice(id: "3", name: "English GB Voice", slug: "en_gb_voice", languages: ["en_gb"]),
            MistralAI.Voice(id: "4", name: "Spanish Voice", slug: "es_voice", languages: ["es_es"])
        ]
        
        // Filter for French
        let frenchVoices = testVoices.filter { voice in
            voice.languages.contains { lang in
                lang.lowercased() == "fr".lowercased() || 
                lang.lowercased().hasPrefix("fr".lowercased().split(separator: "_")[0])
            }
        }
        XCTAssertEqual(frenchVoices.count, 1)
        XCTAssertEqual(frenchVoices[0].id, "1")
        
        // Filter for English (should match both en_us and en_gb)
        let englishVoices = testVoices.filter { voice in
            voice.languages.contains { lang in
                lang.lowercased() == "en".lowercased() || 
                lang.lowercased().hasPrefix("en".lowercased().split(separator: "_")[0])
            }
        }
        XCTAssertEqual(englishVoices.count, 2)
    }
    
    // MARK: - Performance Tests
    
    func testPerformanceExample() {
        measure {
            do {
                let _ = try MistralAI(apiKey: "test-key")
            } catch {
                XCTFail("Should not throw error: \(error)")
            }
        }
    }
    
    // MARK: - Combined TTS and STT Test
    
    func testCombinedTTSAndSTT() {
        let ttsExpectation = expectation(description: "TTS should complete")
        let sttExpectation = expectation(description: "STT should complete")
        
        Task {
            do {
                // Utiliser la clé API depuis l'environnement
                guard let apiKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] else {
                    XCTFail("MISTRAL_API_KEY environment variable not set")
                    return
                }
                
                let mistral = try MistralAI(apiKey: apiKey)
                
                // Texte à synthétiser en français
                let textToSynthesize = "Bonjour, je suis une paire de lunettes connectées. Je peux t'aider dans tes tâches quotidiennes."
                
                // Synthétiser le texte en audio. synthesize() already returns the decoded raw
                // audio bytes — the API's 200 response is JSON with a base64 "audio_data" field
                // (not raw audio directly in the HTTP body), and MistralAI.synthesize() decodes
                // that internally, so no JSON/base64 handling is needed here.
                let audioData = try await mistral.synthesize(
                    text: textToSynthesize
                )

                print("TTS succeeded: Audio data generated with \(audioData.count) bytes")
                ttsExpectation.fulfill()
                
                // Vérifier que les données audio ne sont pas vides
                XCTAssertFalse(audioData.isEmpty, "Audio data should not be empty")
                
                // Sauvegarder les données audio dans un fichier temporaire pour vérification
                let tempAudioFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_audio.mp3")
                try audioData.write(to: tempAudioFileURL)
                print("Audio data saved to: \(tempAudioFileURL.path)")
                
                // Vérifier que le fichier audio existe
                XCTAssertTrue(FileManager.default.fileExists(atPath: tempAudioFileURL.path), "Audio file should exist")
                
                // Lire le fichier audio pour vérification
                let fileData = try Data(contentsOf: tempAudioFileURL)
                XCTAssertEqual(fileData.count, audioData.count, "File data should match audio data")
                
                // Transcrire les données audio générées
                let transcription = try await mistral.transcribe(
                    audioData: fileData,
                    fileName: "test_audio.mp3",
                    language: "fr",
                    model: "voxtral-mini-latest"
                )
                
                print("STT succeeded: Transcription is \(transcription)")
                
                // Vérifier que la transcription est approximativement cohérente avec le texte original
                let originalWords = textToSynthesize.lowercased().components(separatedBy: .whitespacesAndNewlines)
                let transcribedWords = transcription.lowercased().components(separatedBy: .whitespacesAndNewlines)
                
                // Calculer le taux de correspondance (au moins 50% des mots doivent correspondre)
                let matchingWords = zip(originalWords, transcribedWords).filter { $0 == $1 }.count
                let matchPercentage = Double(matchingWords) / Double(originalWords.count)
                
                XCTAssertGreaterThanOrEqual(matchPercentage, 0.5, "Transcription should be at least 50% accurate")
                
                sttExpectation.fulfill()
                
            } catch {
                XCTFail("Test failed with error: \(error.localizedDescription)")
            }
        }
        
        waitForExpectations(timeout: 60, handler: nil)
    }
}
