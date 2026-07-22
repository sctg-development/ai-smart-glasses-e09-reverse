/*
 * MIT License
 *
 * Copyright (c) 2026 Ronan Le Meillat - SCTG Development
 */

import Opus
import AVFoundation
import Foundation

// MARK: - Opus Decoder Helper

/// Helper class to decode Opus packets to PCM audio
public final class OpusDecoder {
    
    // MARK: - Properties
    
    private let decoder: Opus.Decoder
    private let sampleRate: Int
    private let channelCount: Int
    
    // MARK: - Initialization
    
    /// Initialize Opus decoder
    /// - Parameters:
    ///   - sampleRate: Output sample rate (default: 16000)
    ///   - channelCount: Number of channels (default: 1 for mono)
    public init(sampleRate: Int = 16000, channelCount: Int = 1) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        
        // Create audio format for Opus decoder
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )!
        
        do {
            decoder = try Opus.Decoder(format: format)
        } catch {
            throw error
        }
    }
    
    // MARK: - Decoding
    
    /// Decode an Opus packet to PCM samples
    /// - Parameter packet: Raw Opus packet data
    /// - Returns: Array of Float32 PCM samples normalized to [-1.0, 1.0]
    public func decode(packet: [UInt8]) throws -> [Float] {
        let packetData = Data(packet)
        let pcmBuffer = try decoder.decode(packetData)
        
        // Convert AVAudioPCMBuffer to Float array
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw NSError(domain: "OpusDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "No float channel data"])
        }
        
        let frameLength = Int(pcmBuffer.frameLength)
        var samples: [Float] = []
        
        for channel in 0..<Int(pcmBuffer.format.channelCount) {
            let channelData = floatChannelData[channel]
            let channelSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            samples.append(contentsOf: channelSamples)
        }
        
        return samples
    }
    
    /// Decode multiple Opus packets to a single PCM buffer
    /// - Parameter packets: Array of Opus packets
    /// - Returns: Concatenated Float32 PCM samples
    public func decode(packets: [[UInt8]]) throws -> [Float] {
        var allPCM: [Float] = []
        
        for packet in packets {
            let pcm = try decode(packet: packet)
            allPCM.append(contentsOf: pcm)
        }
        
        return allPCM
    }
}
