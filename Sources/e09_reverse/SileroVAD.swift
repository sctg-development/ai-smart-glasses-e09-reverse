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

// MARK: - VAD Types and Protocol

/// Error types for VAD operations
public enum VADError: LocalizedError {
    case modelLoadFailed(String)
    case invalidAudioFormat
    case processingFailed(String)
    case unsupportedSampleRate
    
    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let message):
            return "VAD model load failed: \(message)"
        case .invalidAudioFormat:
            return "Invalid audio format for VAD processing"
        case .processingFailed(let message):
            return "VAD processing failed: \(message)"
        case .unsupportedSampleRate:
            return "Unsupported sample rate for VAD processing"
        }
    }
}

/// Represents a detected speech segment
public struct SpeechSegment {
    public var startSample: Int
    public var endSample: Int
    public var startTime: Double  // in seconds
    public var endTime: Double    // in seconds
    
    public init(startSample: Int, endSample: Int, startTime: Double, endTime: Double) {
        self.startSample = startSample
        self.endSample = endSample
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Protocol for Voice Activity Detection implementations
public protocol VoiceActivityDetector {
    /// Sample rate the VAD model expects
    var sampleRate: Int { get }
    
    /// Detection threshold (0.0 to 1.0)
    var threshold: Float { get set }

    /// Minimum number of samples `process(audio:sampleRate:)`/`isSilence(audio:)` need in a
    /// SINGLE call to produce any result at all (Silero-VAD's window size, e.g. 576 samples/36ms
    /// for the classic ONNX model, 4160 samples/260ms for the "Unified 256ms" CoreML model).
    /// Callers feeding smaller chunks one at a time (e.g. a single ~20ms BLE audio packet) will
    /// always get back an empty segment list / `isSilence == true`, since there's never enough
    /// audio in one call to run inference — they must accumulate at least this many NEW samples
    /// before calling either method.
    var requiredSampleCount: Int { get }
    
    /// Initialize the VAD model
    init(modelPath: URL, sampleRate: Int, threshold: Float) throws
    
    /// Process audio chunk and return detected speech segments
    func process(audio: [Float], sampleRate: Int) throws -> [SpeechSegment]
    
    /// Check if an audio chunk is silence
    func isSilence(audio: [Float]) throws -> Bool

    /// Runs one inference over EXACTLY `requiredSampleCount` samples of new audio and reports
    /// whether THIS chunk, on its own, is currently speech (raw model probability >= threshold).
    /// The model's recurrent state (hidden/cell state) still advances across calls exactly like
    /// `process`/`isSilence` do, so this is safe to call repeatedly on consecutive streaming
    /// windows for accurate model behavior — but UNLIKE `process`/`isSilence`, it does NOT go
    /// through the `triggered` hysteresis state machine used for whole-file segment-boundary
    /// detection. That state machine only emits a NEW segment on the silence→speech transition;
    /// calling `isSilence` once per streaming window means every window AFTER the first one of a
    /// continuous utterance sees `triggered` already `true` and reports an (incorrectly) EMPTY
    /// segment list — i.e. `isSilence` would keep saying "silence" for as long as speech actually
    /// continues. Use this method instead for any live, window-by-window "is the mic hot right
    /// now" check; reserve `process`/`isSilence` for one-shot whole-clip analysis.
    /// - Parameter chunk: exactly `requiredSampleCount` samples of NEW (non-overlapping) audio.
    func containsSpeech(chunk: [Float]) throws -> Bool
    
    /// Reset internal state for new audio stream
    func reset()
}

// MARK: - VAD Configuration

/// Configuration parameters for Silero-VAD
public struct SileroVADConfig {
    public let sampleRate: Int
    public let windowSizeMs: Int
    public let contextSamples: Int
    public let minSilenceDurationMs: Int
    public let speechPadMs: Int
    public let minSpeechDurationMs: Int
    public let threshold: Float
    
    public init(
        sampleRate: Int = 16000,
        windowSizeMs: Int = 32,
        contextSamples: Int = 64,
        minSilenceDurationMs: Int = 100,
        speechPadMs: Int = 30,
        minSpeechDurationMs: Int = 250,
        threshold: Float = 0.5
    ) {
        self.sampleRate = sampleRate
        self.windowSizeMs = windowSizeMs
        self.contextSamples = contextSamples
        self.minSilenceDurationMs = minSilenceDurationMs
        self.speechPadMs = speechPadMs
        self.minSpeechDurationMs = minSpeechDurationMs
        self.threshold = threshold
    }
    
    // Computed properties
    public var windowSizeSamples: Int {
        return sampleRate * windowSizeMs / 1000
    }
    
    public var effectiveWindowSize: Int {
        return windowSizeSamples + contextSamples
    }
    
    public var minSilenceSamples: Int {
        return sampleRate * minSilenceDurationMs / 1000
    }
    
    public var speechPadSamples: Int {
        return sampleRate * speechPadMs / 1000
    }
    
    public var minSpeechSamples: Int {
        return sampleRate * minSpeechDurationMs / 1000
    }
}