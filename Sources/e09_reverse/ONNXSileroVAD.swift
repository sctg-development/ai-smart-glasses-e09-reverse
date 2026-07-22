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

import Foundation

// Only import onnxruntime if available
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// Voice Activity Detector using ONNX Runtime as fallback
public final class ONNXSileroVAD: VoiceActivityDetector {
    
    // MARK: - Properties
    
    public let sampleRate: Int
    public var threshold: Float
    
    #if canImport(OnnxRuntimeBindings)
    private static let env: ORTEnv = {
        // swiftlint:disable:next force_try
        try! ORTEnv(loggingLevel: .warning)
    }()
    private let session: ORTSession
    #endif
    private let config: SileroVADConfig
    public var requiredSampleCount: Int { config.effectiveWindowSize }
    
    // State tracking for streaming
    private var state: [Float]
    private var context: [Float]
    private var triggered: Bool = false
    private var tempEnd: Int = 0
    private var currentSample: Int = 0
    private var totalSampleSize: Int = 0
    
    // MARK: - Initialization
    
    public init(modelPath: URL, sampleRate: Int = 16000, threshold: Float = 0.5) throws {
        self.sampleRate = sampleRate
        self.threshold = threshold
        
        // Initialize configuration
        self.config = SileroVADConfig(
            sampleRate: sampleRate,
            threshold: threshold
        )
        
        // Initialize state vectors
        self.state = Array(repeating: 0.0, count: 2 * 1 * 128)
        self.context = Array(repeating: 0.0, count: config.contextSamples)
        
        #if canImport(OnnxRuntimeBindings)
        do {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            
            self.session = try ORTSession(
                env: Self.env,
                modelPath: modelPath.path,
                sessionOptions: options
            )
        } catch {
            let errorMessage = "Failed to load ONNX model at " + modelPath.path + ": " + error.localizedDescription
            throw VADError.modelLoadFailed(errorMessage)
        }
        #else
        throw VADError.modelLoadFailed("ONNX Runtime not available. Please use CoreML version.")
        #endif
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
        state = Array(repeating: 0.0, count: 2 * 1 * 128)
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
            let errorMessage = "Chunk size " + String(chunk.count) + " < expected " + String(expectedSize)
            throw VADError.processingFailed(errorMessage)
        }
        
        let inputChunk = Array(chunk[0..<expectedSize])
        
        #if canImport(OnnxRuntimeBindings)
        do {
            let inputTensor = try Self.makeORTValue(floats: inputChunk, shape: [1, expectedSize])
            let stateTensor = try Self.makeORTValue(floats: state, shape: [2, 1, 128])
            let srTensor = try Self.makeORTValue(int64s: [Int64(sampleRate)], shape: [1])
            
            let inputs: [String: ORTValue] = [
                "input": inputTensor,
                "state": stateTensor,
                "sr": srTensor
            ]
            
            let outputs = try session.run(
                withInputs: inputs,
                outputNames: ["output", "stateN"],
                runOptions: nil
            )
            
            // Extract output probability
            guard let outputValue = outputs["output"] else {
                throw VADError.processingFailed("No output in ONNX prediction")
            }
            let output = try Self.floatArray(from: outputValue)
            
            // Update state for next iteration
            if let stateValue = outputs["stateN"] {
                state = try Self.floatArray(from: stateValue)
            }
            
            return output[0]
            
        } catch {
            let errorMessage = "ONNX prediction failed: " + error.localizedDescription
            throw VADError.processingFailed(errorMessage)
        }
        #else
        throw VADError.processingFailed("ONNX Runtime not available")
        #endif
    }
    
    #if canImport(OnnxRuntimeBindings)
    private static func makeORTValue(floats: [Float], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: floats, length: floats.count * MemoryLayout<Float>.size)
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }
    
    private static func makeORTValue(int64s: [Int64], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: int64s, length: int64s.count * MemoryLayout<Int64>.size)
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }
    
    private static func floatArray(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData()
        var floats = [Float](repeating: 0, count: data.length / MemoryLayout<Float>.size)
        data.getBytes(&floats, length: data.length)
        return floats
    }
    #endif
}
