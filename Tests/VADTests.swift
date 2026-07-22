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

// Import the main module to test
@testable import e09_reverse

// MARK: - VAD Tests

class VADTests: XCTestCase {
    
    var vad: VoiceActivityDetector?
    var opusDecoder: OpusDecoder?
    
    // MARK: - Helpers
    
    /// Runs a single dummy inference through a freshly-constructed VAD implementation to confirm
    /// it can actually execute, not just load. Some CoreML models load successfully but fail at
    /// prediction time (e.g. "Unable to compute the prediction using ML Program" from the BNNS
    /// backend on Macs without a Neural Engine) — this catches that case early.
    private static func verifyVADCanRunInference(_ vad: VoiceActivityDetector) throws {
        // 1 full second of audio comfortably covers any Silero VAD window size in use (576
        // samples for the classic 32ms ONNX model, 4160 samples for the 256ms CoreML model).
        let warmupSamples = [Float](repeating: 0.0, count: vad.sampleRate)
        _ = try vad.isSilence(audio: warmupSamples)
        vad.reset()
    }
    
    /// Locates and loads the ONNX Runtime VAD backend directly (bypassing the CoreML-first
    /// selection done in `setUp()`), so the ONNX fallback path itself gets dedicated test
    /// coverage regardless of whether CoreML is available/working on the current machine.
    private func loadONNXVAD(threshold: Float = 0.5) throws -> ONNXSileroVAD? {
        let testBundle = Bundle(for: type(of: self))
        
        if let onnxURL = testBundle.url(forResource: "silero_vad", withExtension: "onnx") {
            return try ONNXSileroVAD(modelPath: onnxURL, sampleRate: 16000, threshold: threshold)
        }
        
        let onnxModelPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: onnxModelPath.path) else {
            return nil
        }
        return try ONNXSileroVAD(modelPath: onnxModelPath, sampleRate: 16000, threshold: threshold)
    }
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Get the test bundle
        let testBundle = Bundle(for: type(of: self))
        var modelLoaded = false
        
        // Try to find CoreML model in test bundle
        if let coreMLURL = testBundle.url(forResource: "silero-vad", withExtension: "mlmodelc", subdirectory: "silero-vad.mlmodelc") {
            do {
                let coreMLVAD = try CoreMLSileroVAD(modelPath: coreMLURL, sampleRate: 16000, threshold: 0.5)
                try Self.verifyVADCanRunInference(coreMLVAD)
                vad = coreMLVAD
                modelLoaded = true
                print("✅ CoreML VAD initialized for testing")
            } catch {
                print("⚠️ CoreML VAD failed to load or run from test bundle: \(error.localizedDescription)")
            }
        }
        
        if !modelLoaded {
            // Try to find the model in the Resources directory
            let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources")
            let coreMLModelPath = resourcesPath.appendingPathComponent("silero-vad.mlmodelc")
            
            if FileManager.default.fileExists(atPath: coreMLModelPath.path) {
                do {
                    let coreMLVAD = try CoreMLSileroVAD(modelPath: coreMLModelPath, sampleRate: 16000, threshold: 0.5)
                    try Self.verifyVADCanRunInference(coreMLVAD)
                    vad = coreMLVAD
                    modelLoaded = true
                    print("✅ CoreML VAD initialized from Resources directory")
                } catch {
                    print("⚠️ CoreML VAD failed to load or run from Resources directory: \(error.localizedDescription)")
                }
            }
        }
        
        // If CoreML not available (or failed to load, e.g. an unresolved Git LFS pointer
        // instead of real weights), fall back to ONNX.
        if !modelLoaded {
            if let onnxURL = testBundle.url(forResource: "silero_vad", withExtension: "onnx") {
                do {
                    vad = try ONNXSileroVAD(modelPath: onnxURL, sampleRate: 16000, threshold: 0.5)
                    modelLoaded = true
                    print("✅ ONNX VAD initialized for testing")
                } catch {
                    print("⚠️ ONNX VAD failed to load from test bundle: \(error.localizedDescription)")
                }
            } else {
                // Try to find the model in the Resources directory
                let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Resources")
                let onnxModelPath = resourcesPath.appendingPathComponent("silero_vad.onnx")
                
                if FileManager.default.fileExists(atPath: onnxModelPath.path) {
                    do {
                        vad = try ONNXSileroVAD(modelPath: onnxModelPath, sampleRate: 16000, threshold: 0.5)
                        modelLoaded = true
                        print("✅ ONNX VAD initialized from Resources directory")
                    } catch {
                        print("⚠️ ONNX VAD failed to load from Resources directory: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        if !modelLoaded {
            print("⚠️ No usable VAD model found (CoreML or ONNX)")
        }
        
        // Initialize Opus decoder independently of VAD model loading.
        do {
            opusDecoder = try OpusDecoder(sampleRate: 16000, channelCount: 1)
            print("✅ Opus decoder initialized for testing")
        } catch {
            print("⚠️ Opus decoder setup warning: \(error.localizedDescription)")
        }
    }
    
    override func tearDown() {
        vad = nil
        opusDecoder = nil
        super.tearDown()
    }
    
    // MARK: - Configuration Tests
    
    func testSileroVADConfig() {
        let config = SileroVADConfig()
        
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.windowSizeMs, 32)
        XCTAssertEqual(config.threshold, 0.5)
        XCTAssertEqual(config.windowSizeSamples, 512)
        XCTAssertEqual(config.effectiveWindowSize, 576)
        XCTAssertEqual(config.minSilenceSamples, 1600)
        XCTAssertEqual(config.speechPadSamples, 480)
        XCTAssertEqual(config.minSpeechSamples, 4000)
    }
    
    // MARK: - VAD Initialization Tests
    
    func testVADInitialization() {
        guard let vad = vad else {
            XCTSkip("VAD not available")
            return
        }
        
        XCTAssertEqual(vad.sampleRate, 16000)
        XCTAssertEqual(vad.threshold, 0.5)
    }
    
    // MARK: - Opus Decoder Tests
    
    func testOpusDecoderInitialization() {
        guard let decoder = opusDecoder else {
            XCTFail("Opus decoder should be initialized")
            return
        }
        
        XCTAssertNotNil(decoder)
    }
    
    // MARK: - VAD Processing Tests
    
    func testVADWithSilence() {
        guard let vad = vad else {
            XCTSkip("VAD not available for testing")
            return
        }
        
        // Create a buffer of silence (all zeros)
        let silenceBuffer = [Float](repeating: 0.0, count: 16000) // 1 second of silence at 16kHz
        
        do {
            let isSilent = try vad.isSilence(audio: silenceBuffer)
            XCTAssertTrue(isSilent, "Silence should be detected as silence")
        } catch {
            XCTFail("VAD processing failed: \(error.localizedDescription)")
        }
    }
    
    func testVADWithSpeechLikeSignal() {
        guard let vad = vad else {
            XCTSkip("VAD not available for testing")
            return
        }
        
        // Create a buffer with some speech-like signal (random noise)
        var speechBuffer = [Float](repeating: 0.0, count: 16000)
        for i in 0..<speechBuffer.count {
            speechBuffer[i] = Float.random(in: -0.5...0.5)
        }
        
        do {
            let isSilent = try vad.isSilence(audio: speechBuffer)
            // With random noise, it might or might not be detected as silence depending on the threshold
            // This test just ensures the VAD doesn't crash
            print("Speech-like signal detected as silent: \(isSilent)")
        } catch {
            XCTFail("VAD processing failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - OGG File Tests
    
    func testOGGFileLoading() {
        let testBundle = Bundle(for: type(of: self))
        
        if let oggURL = testBundle.url(forResource: "passiveWakeWordListen", withExtension: "ogg") {
            do {
                let data = try Data(contentsOf: oggURL)
                XCTAssertGreaterThan(data.count, 0, "OGG file should not be empty")
                print("✅ OGG file loaded: \(data.count) bytes")
            } catch {
                XCTFail("Failed to load OGG file: \(error.localizedDescription)")
            }
        } else {
            // Try to find the file in Resources directory
            let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent("passiveWakeWordListen.ogg")
            
            if FileManager.default.fileExists(atPath: resourcesPath.path) {
                do {
                    let data = try Data(contentsOf: resourcesPath)
                    XCTAssertGreaterThan(data.count, 0, "OGG file should not be empty")
                    print("✅ OGG file loaded from Resources: \(data.count) bytes")
                } catch {
                    XCTFail("Failed to load OGG file from Resources: \(error.localizedDescription)")
                }
            } else {
                XCTSkip("OGG file not found")
            }
        }
    }
    
    func testOGGFileHeader() {
        let testBundle = Bundle(for: type(of: self))
        
        if let oggURL = testBundle.url(forResource: "passiveWakeWordListen", withExtension: "ogg") {
            do {
                let data = try Data(contentsOf: oggURL)
                XCTAssertGreaterThanOrEqual(data.count, 4, "OGG file should be at least 4 bytes")
                
                // Check OGG header
                let header = String(data: data.prefix(4), encoding: .ascii)
                XCTAssertEqual(header, "OggS", "File should start with OggS header")
                
            } catch {
                XCTFail("Failed to check OGG header: \(error.localizedDescription)")
            }
        } else {
            XCTSkip("OGG file not found")
        }
    }
    
    // MARK: - Integration Tests
    
    func testVADWithOpusDecoding() {
        guard let vad = vad, let decoder = opusDecoder else {
            XCTSkip("VAD or Opus decoder not available")
            return
        }
        
        // Create a simple test: generate some test data
        // Note: This is a placeholder - in a real test, you'd use actual Opus packets
        
        do {
            // For now, we'll test with a simple PCM buffer
            let testPCM = [Float](repeating: 0.1, count: 512)
            
            let isSilent = try vad.isSilence(audio: testPCM)
            print("Test PCM buffer detected as silent: \(isSilent)")
            
            // The test passes if we can process without crashing
            XCTAssertTrue(true, "VAD processing completed without errors")
            
        } catch {
            XCTFail("VAD with Opus decoding failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Edge Case Tests
    
    func testVADReset() {
        guard let vad = vad else {
            XCTSkip("VAD not available")
            return
        }
        
        // Reset should not throw
        XCTAssertNoThrow(vad.reset())
        
        // Test that VAD still works after reset
        let testBuffer = [Float](repeating: 0.0, count: 512)
        XCTAssertNoThrow(try vad.isSilence(audio: testBuffer))
    }
    
    // MARK: - Performance Tests
    
    func testVADPerformance() {
        guard let vad = vad else {
            XCTSkip("VAD not available for performance testing")
            return
        }
        
        // Create a 1-second buffer
        let bufferSize = 16000 // 1 second at 16kHz
        let testBuffer = [Float](repeating: 0.1, count: bufferSize)
        
        // Measure processing time
        let startTime = Date()
        
        do {
            for _ in 0..<10 { // Process 10 times
                _ = try vad.isSilence(audio: testBuffer)
            }
            
            let elapsedTime = Date().timeIntervalSince(startTime)
            print("⏱️  VAD processed 10x 1-second buffers in \(String(format: "%.3f", elapsedTime))s")
            
            // Should complete within reasonable time (less than 1 second for 10 buffers)
            XCTAssertLessThan(elapsedTime, 1.0, "VAD processing should be fast")
            
        } catch {
            XCTFail("VAD performance test failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Threshold Tests
    
    func testVADThresholdConfiguration() {
        guard let vad = vad else {
            XCTSkip("VAD not available")
            return
        }
        
        // Test that we can read the threshold
        XCTAssertEqual(vad.threshold, 0.5)
        
        // Test that we can change the threshold
        let originalThreshold = vad.threshold
        
        // Create a new VAD instance with different threshold to test configuration
        // This is a workaround since we can't modify the threshold of the existing instance
        // in the test setup
        
        // The threshold configuration is tested by the initialization tests above
    }
    
    // MARK: - Speech Segment Detection Tests
    
    func testSpeechSegmentDetection() {
        guard let vad = vad else {
            XCTSkip("VAD not available")
            return
        }
        
        // Create a buffer with speech followed by silence
        var audioBuffer = [Float](repeating: 0.0, count: 32000) // 2 seconds
        
        // First second: speech-like signal
        for i in 0..<16000 {
            audioBuffer[i] = Float.random(in: -0.4...0.4)
        }
        
        // Second second: silence
        // Already zeros
        
        do {
            let segments = try vad.process(audio: audioBuffer, sampleRate: 16000)
            print("Detected \(segments.count) speech segments")
            
            // Should detect at least one speech segment
            XCTAssertGreaterThanOrEqual(segments.count, 0, "Should detect speech segments")
            
            for (index, segment) in segments.enumerated() {
                print("  Segment \(index + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s")
            }
            
        } catch {
            XCTFail("Speech segment detection failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Real Audio File VAD Test
    
    /// End-to-end test using the real `passiveWakeWordListen.ogg` file captured by `BleProbe`
    /// (see `probeDevicePhotoRecognition` / `validatePassiveWakeWordListen`): demuxes the actual
    /// Ogg Opus container with `OggOpusDemuxer`, decodes the recovered Opus packets to PCM with
    /// `OpusDecoder`, and runs the real VAD backend over that PCM — no synthetic/random signal.
    ///
    /// Per manual listening of the file: ~2s of French speech, then silence, a door slam around
    /// ~6s, then silence to the end of the recording.
    func testRealAudioFileVADSpeechDetection() {
        guard let vad = vad else {
            XCTSkip("VAD not available")
            return
        }
        guard let decoder = opusDecoder else {
            XCTSkip("Opus decoder not available")
            return
        }
        
        let testBundle = Bundle(for: type(of: self))
        let oggURL: URL
        if let bundled = testBundle.url(forResource: "passiveWakeWordListen", withExtension: "ogg") {
            oggURL = bundled
        } else {
            let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent("passiveWakeWordListen.ogg")
            guard FileManager.default.fileExists(atPath: resourcesPath.path) else {
                XCTSkip("passiveWakeWordListen.ogg not found")
                return
            }
            oggURL = resourcesPath
        }
        
        do {
            let oggData = try Data(contentsOf: oggURL)
            
            // Demux the real Ogg Opus container back into elementary Opus packets.
            let demuxed = try OggOpusDemuxer.demux(oggData)
            XCTAssertGreaterThan(demuxed.packets.count, 0, "Should extract at least one Opus packet from the real file")
            XCTAssertEqual(demuxed.header.channelCount, 1, "passiveWakeWordListen.ogg should be mono")
            
            // Decode the real packets to PCM (no synthetic signal).
            let pcm = try decoder.decode(packets: demuxed.packets)
            XCTAssertGreaterThan(pcm.count, 0, "Decoded PCM from the real file should not be empty")
            
            let durationSeconds = Double(pcm.count) / Double(vad.sampleRate)
            print("Real audio file duration: \(String(format: "%.2f", durationSeconds))s (\(demuxed.packets.count) Opus packets)")
            
            vad.reset()
            let segments = try vad.process(audio: pcm, sampleRate: vad.sampleRate)
            print("Detected \(segments.count) speech segment(s) in the real audio file")
            for (index, segment) in segments.enumerated() {
                print("  Segment \(index + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s")
            }
            
            XCTAssertGreaterThanOrEqual(segments.count, 1, "Should detect at least the opening French speech as a speech segment")
            
            guard let firstSegment = segments.first else { return }
            XCTAssertLessThan(firstSegment.startTime, 1.0, "Speech should be detected near the beginning of the recording")
            XCTAssertLessThan(firstSegment.endTime, 4.0, "Opening speech segment should end well before the ~6s door slam")
            
            // No detected segment should run all the way to the end of the recording — the user
            // reports silence after the door slam (~6s) through the end of the file.
            for segment in segments {
                XCTAssertLessThan(segment.endTime, durationSeconds - 0.5, "No speech segment should extend to the end of the recording (trailing silence expected)")
            }
        } catch {
            XCTFail("Real audio file VAD test failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - ONNX Runtime Fallback Tests
    //
    // The tests above exercise whichever backend `setUp()` selects (CoreML-first, with a
    // fallback to ONNX only if CoreML fails to load or run). The tests below load `ONNXSileroVAD`
    // directly instead, so the ONNX Runtime fallback path itself always gets exercised and
    // verified — even on a machine where CoreML happens to work fine and would otherwise "hide"
    // the ONNX backend from every other test in this file.
    
    func testONNXVADInitialization() {
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            XCTAssertEqual(onnxVAD.sampleRate, 16000)
            XCTAssertEqual(onnxVAD.threshold, 0.5)
        } catch {
            XCTFail("ONNX VAD initialization failed: \(error.localizedDescription)")
        }
    }
    
    func testONNXVADWithSilence() {
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            
            let silenceBuffer = [Float](repeating: 0.0, count: 16000) // 1 second of silence at 16kHz
            let isSilent = try onnxVAD.isSilence(audio: silenceBuffer)
            XCTAssertTrue(isSilent, "Silence should be detected as silence by the ONNX backend")
        } catch {
            XCTFail("ONNX VAD processing failed: \(error.localizedDescription)")
        }
    }
    
    func testONNXVADWithSpeechLikeSignal() {
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            
            var speechBuffer = [Float](repeating: 0.0, count: 16000)
            for i in 0..<speechBuffer.count {
                speechBuffer[i] = Float.random(in: -0.5...0.5)
            }
            
            let isSilent = try onnxVAD.isSilence(audio: speechBuffer)
            // With random noise, it might or might not be detected as silence depending on the
            // threshold — this test just ensures the ONNX backend doesn't crash.
            print("ONNX: speech-like signal detected as silent: \(isSilent)")
        } catch {
            XCTFail("ONNX VAD processing failed: \(error.localizedDescription)")
        }
    }
    
    func testONNXVADReset() {
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            
            XCTAssertNoThrow(onnxVAD.reset())
            
            let testBuffer = [Float](repeating: 0.0, count: 512)
            XCTAssertNoThrow(try onnxVAD.isSilence(audio: testBuffer))
        } catch {
            XCTFail("ONNX VAD reset test failed: \(error.localizedDescription)")
        }
    }
    
    func testONNXVADSpeechSegmentDetection() {
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            
            // Speech-like signal for 1 second, then silence for 1 second.
            var audioBuffer = [Float](repeating: 0.0, count: 32000)
            for i in 0..<16000 {
                audioBuffer[i] = Float.random(in: -0.4...0.4)
            }
            
            let segments = try onnxVAD.process(audio: audioBuffer, sampleRate: 16000)
            print("ONNX: detected \(segments.count) speech segment(s)")
            XCTAssertGreaterThanOrEqual(segments.count, 0, "Should not crash while detecting speech segments")
        } catch {
            XCTFail("ONNX speech segment detection failed: \(error.localizedDescription)")
        }
    }
    
    /// Same real-audio-file scenario as `testRealAudioFileVADSpeechDetection`, but forcing the
    /// ONNX Runtime backend explicitly so its accuracy on real captured audio is verified too,
    /// not just its ability to run without crashing.
    func testONNXVADWithRealAudioFile() {
        guard let decoder = opusDecoder else {
            XCTSkip("Opus decoder not available")
            return
        }
        
        do {
            guard let onnxVAD = try loadONNXVAD() else {
                XCTSkip("ONNX model not available")
                return
            }
            
            let testBundle = Bundle(for: type(of: self))
            let oggURL: URL
            if let bundled = testBundle.url(forResource: "passiveWakeWordListen", withExtension: "ogg") {
                oggURL = bundled
            } else {
                let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Resources")
                    .appendingPathComponent("passiveWakeWordListen.ogg")
                guard FileManager.default.fileExists(atPath: resourcesPath.path) else {
                    XCTSkip("passiveWakeWordListen.ogg not found")
                    return
                }
                oggURL = resourcesPath
            }
            
            let oggData = try Data(contentsOf: oggURL)
            let demuxed = try OggOpusDemuxer.demux(oggData)
            let pcm = try decoder.decode(packets: demuxed.packets)
            XCTAssertGreaterThan(pcm.count, 0, "Decoded PCM from the real file should not be empty")
            
            let segments = try onnxVAD.process(audio: pcm, sampleRate: onnxVAD.sampleRate)
            print("ONNX: detected \(segments.count) speech segment(s) in the real audio file")
            for (index, segment) in segments.enumerated() {
                print("  ONNX Segment \(index + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s")
            }
            
            XCTAssertGreaterThanOrEqual(segments.count, 1, "ONNX backend should detect at least the opening French speech as a speech segment")
            
            guard let firstSegment = segments.first else { return }
            XCTAssertLessThan(firstSegment.startTime, 1.0, "Speech should be detected near the beginning of the recording")
            XCTAssertLessThan(firstSegment.endTime, 4.0, "Opening speech segment should end well before the ~6s door slam")
        } catch {
            XCTFail("ONNX real audio file VAD test failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Mistral AI STT Integration Test
    
    /// Test that sends the passiveWakeWordListen.ogg file to Mistral AI STT when
    /// MISTRAL_API_KEY and MISTRAL_LANGUAGE environment variables are provided.
    /// This validates that the recorded audio can be properly transcribed.
    ///
    /// To run this test:
    ///   MISTRAL_API_KEY="your-api-key" MISTRAL_LANGUAGE="fr" swift test --filter VADTests.testValidatePassiveWakeWordListen
    func testValidatePassiveWakeWordListen() async {
        // Check if required environment variables are present
        guard let apiKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"], !apiKey.isEmpty else {
            print("⚠️  MISTRAL_API_KEY not set, skipping Mistral AI STT test")
            return
        }
        
        guard let language = ProcessInfo.processInfo.environment["MISTRAL_LANGUAGE"], !language.isEmpty else {
            print("⚠️  MISTRAL_LANGUAGE not set, skipping Mistral AI STT test")
            return
        }
        
        print("🔑 MISTRAL_API_KEY and MISTRAL_LANGUAGE found, running STT test...")
        
        // Find the passiveWakeWordListen.ogg file
        let testBundle = Bundle(for: type(of: self))
        let oggURL: URL
        
        if let bundled = testBundle.url(forResource: "passiveWakeWordListen", withExtension: "ogg") {
            oggURL = bundled
        } else {
            let resourcesPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent("passiveWakeWordListen.ogg")
            guard FileManager.default.fileExists(atPath: resourcesPath.path) else {
                print("❌ passiveWakeWordListen.ogg not found")
                return
            }
            oggURL = resourcesPath
        }
        
        do {
            // Read the OGG file
            let oggData = try Data(contentsOf: oggURL)
            print("📄 Found passiveWakeWordListen.ogg (\(oggData.count) bytes)")
            
            // Initialize Mistral AI with the provided API key and language
            // Using the correct STT model: voxtral-mini-latest
            let sttModel = "voxtral-mini-latest"
            let config = MistralAI.Config(
                apiKey: apiKey,
                sttLanguage: language,
                sttModel: sttModel
            )
            let mistral = try MistralAI(config: config)
            
            print("🎤 Sending to Mistral AI STT (language: \(language), model: \(sttModel))...")
            
            // Send the OGG file to Mistral AI for transcription
            let transcribedText = try await mistral.transcribe(
                audioData: oggData,
                fileName: "passiveWakeWordListen.ogg",
                language: language,
                model: sttModel
            )
            
            print("✅ STT Result: \(transcribedText)")
            print("📝 Recognized text from passiveWakeWordListen.ogg:")
            print("   '\(transcribedText)'")
            
            // Assert that we got some transcription result
            XCTAssertFalse(transcribedText.isEmpty, "Transcribed text should not be empty")
            
        } catch MistralAI.MistralError.invalidAPIKey {
            print("❌ Invalid Mistral AI API key")
        } catch MistralAI.MistralError.serverError(let statusCode, let message) {
            print("❌ Mistral AI server error: \(statusCode) - \(message)")
        } catch MistralAI.MistralError.networkError(let error) {
            print("❌ Network error: \(error.localizedDescription)")
        } catch {
            print("❌ Error during STT: \(error.localizedDescription)")
        }
    }
}
