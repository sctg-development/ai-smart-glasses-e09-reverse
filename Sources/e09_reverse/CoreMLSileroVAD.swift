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

import CoreML
import Foundation

// MARK: - CoreML-based Silero VAD Implementation

/// Voice Activity Detector using CoreML for optimal performance on macOS
public final class CoreMLSileroVAD: VoiceActivityDetector {
    
    // MARK: - Properties
    
    public let sampleRate: Int
    public var threshold: Float
    public var requiredSampleCount: Int { config.effectiveWindowSize }
    
    private let model: MLModel
    private let config: SileroVADConfig
    private let stateLength: Int
    
    // State tracking for streaming. The Silero VAD v6 "unified" CoreML model uses an LSTM cell
    // with separate hidden/cell state vectors instead of the combined [2, 1, 128] GRU-style
    // state used by the classic v4/v5 ONNX export. The vector length (`stateLength`) and the
    // audio window length are both detected from the model's real input schema at load time,
    // so this class adapts automatically to whichever Silero VAD CoreML export is provided
    // (e.g. the classic 576-sample window or the "Unified 256ms" 4160-sample window).
    private var hiddenState: [Float]
    private var cellState: [Float]
    private var context: [Float]
    private var triggered: Bool = false
    private var tempEnd: Int = 0
    private var currentSample: Int = 0
    private var totalSampleSize: Int = 0
    
    // MARK: - Initialization
    
    public init(modelPath: URL, sampleRate: Int = 16000, threshold: Float = 0.5) throws {
        self.sampleRate = sampleRate
        self.threshold = threshold
        
        // Load once purely to read the model's real input schema. Compute units only affect
        // *execution*, not loading, so this is safe regardless of which backend ends up working.
        let probeModel: MLModel
        do {
            probeModel = try MLModel(contentsOf: modelPath)
        } catch {
            throw VADError.modelLoadFailed("Failed to load CoreML model at \(modelPath.path): \(error.localizedDescription)")
        }
        let audioInputLength = Self.multiArrayLength(of: probeModel, inputNamed: "audio_input") ?? 576
        let stateLength = Self.multiArrayLength(of: probeModel, inputNamed: "hidden_state") ?? 128
        self.stateLength = stateLength
        
        // Pick the best-working compute unit configuration for THIS machine instead of forcing
        // one. `.all` lets CoreML auto-select the optimal backend (e.g. the Neural Engine on
        // Apple Silicon); some model/hardware combinations fail only at *prediction* time (a
        // BNNS/E5RT execution error observed on Intel Macs with certain models), so each
        // candidate is verified with a real smoke inference before being accepted, falling back
        // to the next one otherwise. This keeps the tool portable across machines.
        let candidateComputeUnits: [MLComputeUnits] = [.all, .cpuAndGPU, .cpuOnly]
        var workingModel: MLModel?
        var lastError: Error?
        for units in candidateComputeUnits {
            let modelConfig = MLModelConfiguration()
            modelConfig.computeUnits = units
            do {
                let candidateModel = try MLModel(contentsOf: modelPath, configuration: modelConfig)
                try Self.smokeTest(candidateModel, audioInputLength: audioInputLength, stateLength: stateLength)
                workingModel = candidateModel
                break
            } catch {
                lastError = error
            }
        }
        guard let selectedModel = workingModel else {
            throw VADError.modelLoadFailed("CoreML model at \(modelPath.path) failed to run on every available compute unit: \(lastError?.localizedDescription ?? "unknown error")")
        }
        self.model = selectedModel
        
        // Initialize configuration to match the model's actual audio window, derived from its
        // real input shape rather than assumed from a specific known model variant.
        let contextSamples = 64
        let windowSizeMs = max(1, ((audioInputLength - contextSamples) * 1000) / sampleRate)
        self.config = SileroVADConfig(
            sampleRate: sampleRate,
            windowSizeMs: windowSizeMs,
            contextSamples: contextSamples,
            threshold: threshold
        )
        
        // Initialize state vectors
        self.hiddenState = Array(repeating: 0.0, count: stateLength)
        self.cellState = Array(repeating: 0.0, count: stateLength)
        self.context = Array(repeating: 0.0, count: config.contextSamples)
    }
    
    /// Reads the last dimension of a named input's MultiArray shape from the model's own
    /// description, e.g. `576` or `4160` for "audio_input", `128` for "hidden_state".
    private static func multiArrayLength(of model: MLModel, inputNamed name: String) -> Int? {
        guard let constraint = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint else {
            return nil
        }
        return constraint.shape.last?.intValue
    }
    
    /// Runs a single dummy (all-zero) prediction to confirm a loaded model can actually execute
    /// with the given compute unit configuration, not just load successfully.
    private static func smokeTest(_ model: MLModel, audioInputLength: Int, stateLength: Int) throws {
        guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: audioInputLength)], dataType: .float32),
              let hiddenArray = try? MLMultiArray(shape: [1, NSNumber(value: stateLength)], dataType: .float32),
              let cellArray = try? MLMultiArray(shape: [1, NSNumber(value: stateLength)], dataType: .float32) else {
            throw VADError.processingFailed("Failed to allocate smoke-test input arrays")
        }
        let inputFeature = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: inputArray),
            "hidden_state": MLFeatureValue(multiArray: hiddenArray),
            "cell_state": MLFeatureValue(multiArray: cellArray)
        ])
        _ = try model.prediction(from: inputFeature)
    }
    
    // MARK: - Public Methods
    
    public func process(audio: [Float], sampleRate: Int) throws -> [SpeechSegment] {
        guard sampleRate == self.sampleRate else {
            throw VADError.invalidAudioFormat
        }
        
        var speechSegments: [SpeechSegment] = []
        let chunkSize = config.windowSizeSamples
        let effectiveWindowSize = config.effectiveWindowSize
        
        // Process audio in chunks
        for i in stride(from: 0, to: audio.count, by: chunkSize) {
            let endIndex = min(i + effectiveWindowSize, audio.count)
            guard endIndex - i >= effectiveWindowSize else { break }
            
            let chunk = Array(audio[i..<endIndex])
            let speechProb = try predict(chunk: chunk)
            
            // Update sample counter
            currentSample += chunkSize
            totalSampleSize += chunkSize
            
            // Speech detection logic
            if speechProb >= threshold {
                if !triggered {
                    triggered = true
                    let start = max(0, currentSample - config.speechPadSamples - chunkSize)
                    speechSegments.append(SpeechSegment(
                        startSample: start,
                        endSample: -1,
                        startTime: Double(start) / Double(sampleRate),
                        endTime: -1
                    ))
                }
            } else {
                if triggered {
                    if speechProb < threshold - 0.15 {
                        if tempEnd == 0 {
                            tempEnd = currentSample
                        }
                        if currentSample - tempEnd >= config.minSilenceSamples {
                            if var lastSegment = speechSegments.last {
                                lastSegment.endSample = tempEnd + config.speechPadSamples - chunkSize
                                lastSegment.endTime = Double(lastSegment.endSample) / Double(sampleRate)
                                speechSegments[speechSegments.count - 1] = lastSegment
                            }
                            tempEnd = 0
                            triggered = false
                        }
                    }
                }
            }
        }
        
        // Finalize active speech segment
        if triggered, var lastSegment = speechSegments.last {
            lastSegment.endSample = totalSampleSize
            lastSegment.endTime = Double(lastSegment.endSample) / Double(sampleRate)
            speechSegments[speechSegments.count - 1] = lastSegment
        }
        
        // Filter out short segments
        speechSegments = speechSegments.filter { segment in
            (segment.endSample - segment.startSample) >= config.minSpeechSamples
        }
        
        return speechSegments
    }
    
    public func isSilence(audio: [Float]) throws -> Bool {
        let segments = try process(audio: audio, sampleRate: sampleRate)
        return segments.isEmpty
    }

    public func containsSpeech(chunk: [Float]) throws -> Bool {
        let speechProb = try predict(chunk: chunk)
        return speechProb >= threshold
    }
    
    public func reset() {
        hiddenState = Array(repeating: 0.0, count: stateLength)
        cellState = Array(repeating: 0.0, count: stateLength)
        context = Array(repeating: 0.0, count: config.contextSamples)
        triggered = false
        tempEnd = 0
        currentSample = 0
        totalSampleSize = 0
    }
    
    // MARK: - Private Methods
    
    private func predict(chunk: [Float]) throws -> Float {
        let expectedSize = config.effectiveWindowSize
        guard chunk.count >= expectedSize else {
            throw VADError.processingFailed("Chunk size \(chunk.count) < expected \(expectedSize)")
        }
        
        let inputChunk = Array(chunk[0..<expectedSize])
        
        // Create audio input array — "audio_input": Float32[1, expectedSize] (4160 for the
        // "Unified 256ms" model this class targets)
        guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: expectedSize)], dataType: .float32) else {
            throw VADError.processingFailed("Failed to create input array")
        }
        
        for (index, value) in inputChunk.enumerated() {
            inputArray[index] = NSNumber(value: value)
        }
        
        // Create LSTM hidden/cell state arrays — "hidden_state"/"cell_state": Float32[1, stateLength]
        guard let hiddenStateArray = try? MLMultiArray(shape: [1, NSNumber(value: stateLength)], dataType: .float32),
              let cellStateArray = try? MLMultiArray(shape: [1, NSNumber(value: stateLength)], dataType: .float32) else {
            throw VADError.processingFailed("Failed to create state arrays")
        }
        
        for (index, value) in hiddenState.enumerated() {
            hiddenStateArray[index] = NSNumber(value: value)
        }
        for (index, value) in cellState.enumerated() {
            cellStateArray[index] = NSNumber(value: value)
        }
        
        // Prepare inputs as MLDictionaryFeatureProvider (no separate sample-rate input — the v6
        // unified model is fixed at 16kHz).
        let inputFeature = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: inputArray),
            "hidden_state": MLFeatureValue(multiArray: hiddenStateArray),
            "cell_state": MLFeatureValue(multiArray: cellStateArray)
        ])
        
        // Run prediction
        do {
            let prediction = try model.prediction(from: inputFeature)
            
            guard let output = prediction.featureValue(for: "vad_output")?.multiArrayValue else {
                throw VADError.processingFailed("No output in prediction")
            }
            
            let speechProb = output[0].floatValue
            
            // Update LSTM state for next iteration
            if let newHidden = prediction.featureValue(for: "new_hidden_state")?.multiArrayValue {
                hiddenState = (0..<newHidden.count).map { newHidden[$0].floatValue }
            }
            if let newCell = prediction.featureValue(for: "new_cell_state")?.multiArrayValue {
                cellState = (0..<newCell.count).map { newCell[$0].floatValue }
            }
            
            return speechProb
            
        } catch {
            throw VADError.processingFailed("Prediction failed: \(error.localizedDescription)")
        }
    }
}
