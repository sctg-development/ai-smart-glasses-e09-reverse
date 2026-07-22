/*
 * MIT License
 *
 * Copyright (c) 2026 Ronan Le Meillat - SCTG Development
 *
 * Example usage of MistralAI module for STT and TTS
 */

import Foundation
import e09_reverse

/// Example class demonstrating Mistral AI usage
public class MistralAIExample {
    
    let mistral: MistralAI
    
    public init(apiKey: String) throws {
        self.mistral = try MistralAI(apiKey: apiKey)
    }
    
    /// Transcribe audio file to text
    public func transcribeExample(audioFilePath: String) async throws -> String {
        print("Transcribing audio file: \(audioFilePath)")
        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioFilePath))
        let transcription = try await mistral.transcribe(audioData: audioData)
        print("Transcription: \(transcription)")
        return transcription
    }
    
    /// Synthesize text to speech
    public func synthesizeExample(text: String, outputPath: String) async throws -> URL {
        print("Synthesizing text: \(text)")
        let audioData = try await mistral.synthesize(text: text)
        try audioData.write(to: URL(fileURLWithPath: outputPath))
        print("Audio saved to: \(outputPath)")
        return URL(fileURLWithPath: outputPath)
    }
    
    /// Full conversation workflow
    public func conversationExample() async throws {
        print("\n=== Mistral AI Conversation Example ===\n")
        
        let question = "Bonjour, comment puis-je vous aider aujourd'hui ?"
        let questionAudioPath = "/tmp/question.mp3"
        let _ = try await synthesizeExample(text: question, outputPath: questionAudioPath)
        
        let reply = "Bien sûr ! Je peux vous expliquer comment utiliser notre service."
        let replyAudioPath = "/tmp/reply.mp3"
        let _ = try await synthesizeExample(text: reply, outputPath: replyAudioPath)
        
        print("✅ Conversation example completed!")
    }
}

@main
struct MistralAIExampleMain {
    static func main() async {
        print("Mistral AI Example")
        
        // Get API key from environment
        guard let apiKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] else {
            print("Set MISTRAL_API_KEY environment variable")
            return
        }
        
        do {
            let example = try MistralAIExample(apiKey: apiKey)
            try await example.conversationExample()
            print("All examples completed!")
        } catch {
            print("Error: \(error)")
        }
    }
}
