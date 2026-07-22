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

// MARK: - Mistral AI Module

/// Mistral AI module for Speech-to-Text (STT) and Text-to-Speech (TTS)
///
/// This module provides access to Mistral AI's audio APIs:
/// - STT: `/v1/audio/transcriptions` - Convert audio to text
/// - TTS: `/v1/audio/speech` - Convert text to audio
/// - Voices: `/v1/audio/voices` - Get available voices
///
/// **Security Note**: The API key is NOT stored in the code. It must be provided
/// at initialization or via environment variable `MISTRAL_API_KEY`.
///
/// Usage:
/// ```swift
/// let mistral = try MistralAI(apiKey: "your-api-key-here")
/// let text = try await mistral.transcribe(audioData: audioData)
/// let audio = try await mistral.synthesize(text: "Bonjour le monde")
/// let voices = try await mistral.fetchVoices()
/// ```
public class MistralAI {
    
    // MARK: - Configuration
    
    /// Configuration structure for Mistral AI
    public struct Config {
        /// API key for Mistral AI (required)
        /// **IMPORTANT**: Never hardcode this in your repository
        public var apiKey: String
        
        /// Base URL for Mistral API
        public var baseURL: String
        
        /// Default language for Speech-to-Text
        public var sttLanguage: String
        
        /// Default model for Speech-to-Text
        public var sttModel: String
        
        /// Default model for Text-to-Speech
        public var ttsModel: String
        
        /// Default voice ID for Text-to-Speech
        public var ttsVoiceID: String
        
        /// Default output format for TTS
        public var ttsOutputFormat: String
        
        /// Initialize configuration with default values
        public init(
            apiKey: String? = nil,
            baseURL: String = "https://api.mistral.ai/v1",
            sttLanguage: String = "fr",
            sttModel: String = "voxtral-mini-latest",
            ttsModel: String = "voxtral-mini-tts-latest",
            ttsVoiceID: String = "49d024dd-981b-4462-bb17-74d381eb8fd7",
            ttsOutputFormat: String = "mp3"
        ) {
            if let apiKey = apiKey {
                self.apiKey = apiKey
            } else if let envKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] {
                self.apiKey = envKey
            } else {
                self.apiKey = ""
            }
            
            self.baseURL = baseURL
            self.sttLanguage = sttLanguage
            self.sttModel = sttModel
            self.ttsModel = ttsModel
            self.ttsVoiceID = ttsVoiceID
            self.ttsOutputFormat = ttsOutputFormat
        }
    }
    
    // MARK: - Voice Structure
    
    /// Voice information from Mistral API
    public struct Voice: Codable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let slug: String
        public let languages: [String]
        public let gender: String?
        public let age: Int?
        public let tags: [String]?
        public let color: String?
        public let description: String?
        public let appearance: String?
        public let retention_notice: Int?
        public let created_at: String?
        public let user_id: String?
        public let trimmed_seconds: String?
        
        public init(id: String, name: String, slug: String, languages: [String], 
                   gender: String? = nil, age: Int? = nil, tags: [String]? = nil,
                   color: String? = nil, description: String? = nil, appearance: String? = nil,
                   retention_notice: Int? = nil, created_at: String? = nil, user_id: String? = nil,
                   trimmed_seconds: String? = nil) {
            self.id = id
            self.name = name
            self.slug = slug
            self.languages = languages
            self.gender = gender
            self.age = age
            self.tags = tags
            self.color = color
            self.description = description
            self.appearance = appearance
            self.retention_notice = retention_notice
            self.created_at = created_at
            self.user_id = user_id
            self.trimmed_seconds = trimmed_seconds
        }
    }
    
    // MARK: - Error Types
    
    /// Mistral AI specific errors
    public enum MistralError: Error, LocalizedError {
        case invalidAPIKey
        case missingAPIKey
        case invalidAudioFile
        case invalidTextInput
        case rateLimitExceeded
        case serverError(statusCode: Int, message: String)
        case networkError(Error)
        case decodingError(Error)
        case unsupportedFormat
        case unknownError(String)
        
        public var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "Invalid Mistral AI API key"
            case .missingAPIKey: return "Mistral AI API key is required"
            case .invalidAudioFile: return "Invalid audio file format or data"
            case .invalidTextInput: return "Invalid text input for TTS"
            case .rateLimitExceeded: return "API rate limit exceeded"
            case .serverError(let statusCode, let message): return "Server error: \(statusCode) - \(message)"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .decodingError(let error): return "Response decoding error: \(error.localizedDescription)"
            case .unsupportedFormat: return "Unsupported audio format"
            case .unknownError(let message): return "Unknown error: \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    private let config: Config
    private let session: URLSession
    
    /// Current configuration
    public var currentConfig: Config { config }
    
    // MARK: - Initialization
    
    /// Initialize Mistral AI with configuration
    public init(config: Config) throws {
        if config.apiKey.isEmpty {
            throw MistralError.missingAPIKey
        }
        self.config = config
        self.session = URLSession(configuration: .default)
    }
    
    /// Initialize Mistral AI with API key (convenience initializer)
    public convenience init(
        apiKey: String,
        sttLanguage: String = "fr",
        sttModel: String = "",
        ttsModel: String = "voxtral-mini-tts-latest",
        ttsVoiceID: String = "49d024dd-981b-4462-bb17-74d381eb8fd7"
    ) throws {
        let config = Config(
            apiKey: apiKey,
            sttLanguage: sttLanguage,
            sttModel: sttModel,
            ttsModel: ttsModel,
            ttsVoiceID: ttsVoiceID
        )
        try self.init(config: config)
    }
    
    // MARK: - Speech-to-Text (STT)
    
    /// Transcribe audio data to text using Mistral AI's STT API
    public func transcribe(
        audioData: Data,
        fileName: String = "audio.wav",
        language: String? = nil,
        model: String? = nil,
        temperature: Float? = nil,
        prompt: String? = nil
    ) async throws -> String {
        guard !audioData.isEmpty else {
            throw MistralError.invalidAudioFile
        }
        
        let endpoint = "\(config.baseURL)/audio/transcriptions"
        guard let url = URL(string: endpoint) else {
            throw MistralError.unknownError("Invalid URL: \(endpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        let sttModel = model ?? config.sttModel
        // Only include model parameter if it's not empty
        if !sttModel.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(sttModel)\r\n".data(using: .utf8)!)
        }
        
        let sttLanguage = language ?? config.sttLanguage
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(sttLanguage)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        
        if let temperature = temperature {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(temperature)\r\n".data(using: .utf8)!)
        }
        
        if let prompt = prompt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    let responseJSON = try JSONDecoder().decode(STTResponse.self, from: data)
                    return responseJSON.text
                case 401: throw MistralError.invalidAPIKey
                case 429: throw MistralError.rateLimitExceeded
                case 400..<500:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                case 500...:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Server error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                default:
                    throw MistralError.unknownError("Unexpected status code: \(httpResponse.statusCode)")
                }
            }
            throw MistralError.unknownError("Invalid response")
        } catch let error as URLError {
            throw MistralError.networkError(error)
        } catch {
            throw MistralError.unknownError(error.localizedDescription)
        }
    }
    
    // MARK: - Text-to-Speech (TTS)
    
    /// Synthesize text to audio using Mistral AI's TTS API
    public func synthesize(
        text: String,
        model: String? = nil,
        voiceID: String? = nil,
        language: String? = nil,
        outputFormat: String? = nil,
        speed: Float? = nil,
        temperature: Float? = nil
    ) async throws -> Data {
        guard !text.isEmpty else {
            throw MistralError.invalidTextInput
        }
        
        let endpoint = "\(config.baseURL)/audio/speech"
        guard let url = URL(string: endpoint) else {
            throw MistralError.unknownError("Invalid URL: \(endpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var requestBody: [String: Any] = [
            "model": model ?? config.ttsModel,
            "input": text,
            "voice_id": voiceID ?? config.ttsVoiceID
        ]

        // Note: `language` is intentionally NOT sent — confirmed on real API responses that
        // /v1/audio/speech rejects it outright (422 "extra_forbidden" on body.language). Only
        // /v1/audio/transcriptions (STT, see transcribe() above) accepts a language field. The
        // `language` parameter is kept here for source compatibility but has no effect; pick a
        // language-appropriate voice via `voiceID` instead (see getAvailableVoices()).
        _ = language

        // The real field name is `response_format` (an enum: pcm|wav|mp3|flac|opus) — a
        // previous version of this code used the wrong key ("output_format") and got a 422 for
        // it, which was misdiagnosed as the FIELD itself being rejected rather than its name
        // being wrong. Requesting it explicitly means we know exactly what container we'll get
        // back instead of guessing from magic bytes downstream.
        requestBody["response_format"] = outputFormat ?? (config.ttsOutputFormat.isEmpty ? "mp3" : config.ttsOutputFormat)

        if let speed = speed {
            requestBody["speed"] = speed
        }
        
        if let temperature = temperature {
            requestBody["temperature"] = temperature
        }
        
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        } catch {
            throw MistralError.unknownError("Failed to encode request: \(error.localizedDescription)")
        }
        
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    // The 200 response is JSON — {"audio_data": "<base64>", ...} — NOT raw audio
                    // bytes directly in the HTTP body. Returning `data` as-is previously wrote
                    // that JSON text to disk with an audio file extension, which every player
                    // then failed to open (it isn't audio at all until base64-decoded).
                    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let base64Audio = root["audio_data"] as? String,
                          let audioData = Data(base64Encoded: base64Audio) else {
                        throw MistralError.decodingError(NSError(domain: "MistralAI", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Expected a JSON body with a base64 'audio_data' field"]))
                    }
                    return audioData
                case 401:
                    throw MistralError.invalidAPIKey
                case 429:
                    throw MistralError.rateLimitExceeded
                case 400..<500:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                case 500...:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Server error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                default:
                    throw MistralError.unknownError("Unexpected status code: \(httpResponse.statusCode)")
                }
            }
            throw MistralError.unknownError("Invalid response")
        } catch let error as URLError {
            throw MistralError.networkError(error)
        } catch {
            throw MistralError.unknownError(error.localizedDescription)
        }
    }
    
    // MARK: - Voice Management
    
    /// Response from /v1/audio/voices endpoint
    private struct VoicesResponse: Codable {
        let items: [Voice]
        let total: Int
        let page: Int
        let page_size: Int
        let total_pages: Int
    }
    
    /// Fetch available voices from Mistral API
    /// - Parameter limit: Maximum number of voices to return (default: 100)
    /// - Returns: Array of available Voice objects
    /// - Throws: MistralError if the request fails
    public func fetchVoices(limit: Int = 100) async throws -> [Voice] {
        let endpoint = "\(config.baseURL)/audio/voices?limit=\(limit)"
        guard let url = URL(string: endpoint) else {
            throw MistralError.unknownError("Invalid URL: \(endpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    let responseJSON = try JSONDecoder().decode(VoicesResponse.self, from: data)
                    return responseJSON.items
                    
                case 401:
                    throw MistralError.invalidAPIKey
                    
                case 429:
                    throw MistralError.rateLimitExceeded
                    
                case 400..<500:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                    
                case 500...:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Server error"
                    throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                    
                default:
                    throw MistralError.unknownError("Unexpected status code: \(httpResponse.statusCode)")
                }
            }
            
            throw MistralError.unknownError("Invalid response")
            
        } catch let error as URLError {
            throw MistralError.networkError(error)
        } catch {
            throw MistralError.unknownError(error.localizedDescription)
        }
    }
    
    /// Get voices for a specific language
    /// - Parameter language: Language code (e.g., "fr_fr", "en_us", "en_gb")
    /// - Returns: Array of voices for the specified language
    public func getVoices(forLanguage language: String) async throws -> [Voice] {
        let allVoices = try await fetchVoices()
        return allVoices.filter { voice in
            voice.languages.contains { lang in
                lang.lowercased() == language.lowercased() || 
                lang.lowercased().hasPrefix(language.lowercased().split(separator: "_")[0])
            }
        }
    }
    
    /// Get voice by ID
    /// - Parameter voiceID: The voice ID
    /// - Returns: Voice object if found
    public func getVoice(byID voiceID: String) async throws -> Voice? {
        let allVoices = try await fetchVoices()
        return allVoices.first { $0.id == voiceID }
    }
    
    // MARK: - Response Types
    
    /// STT API response structure
    private struct STTResponse: Codable {
        let text: String
    }
    
    // MARK: - Utility Methods
    
    /// Check if API key is valid by making a test request
    public func validateAPIKey() async throws -> Bool {
        do {
            let testText = "Test"
            _ = try await synthesize(text: testText)
            return true
        } catch MistralError.invalidAPIKey {
            return false
        } catch {
            throw error
        }
    }
    
    /// Get available voices for TTS (static fallback)
    public static func getAvailableVoices() -> [String: [String: String]] {
        return [
            "fr": [
                "fr_marie_neutral": "49d024dd-981b-4462-bb17-74d381eb8fd7",
                "fr_marie_happy": "5a271406-039d-46fe-835b-fbbb00eaf08d",
                "fr_marie_sad": "4adeb2c6-25a3-44bc-8100-5234dfc1193b",
                "fr_marie_excited": "2f62b1af-aea3-4079-9d10-7ca665ee7243",
                "fr_marie_curious": "e0580ce5-e63c-4cbe-88c8-a983b80c5f1f",
                "fr_marie_angry": "a7c07cdc-1c35-4d87-a938-c610a654f600"
            ],
            "en": [
                "en_amanda_neutral": "742e5659-29e0-4747-a1b5-a61133426781",
                "en_oliver_neutral": "8742a873-3012-4141-982d-272a7372991d"
            ],
            "de": [
                "de_klaus_neutral": "85444655-5437-4729-875a-01b330f05b03",
                "de_anna_neutral": "93444356-5437-4729-875a-01b330f05b04"
            ],
            "es": [
                "es_sofia_neutral": "a0346055-3824-4a72-829f-1f651d7d0369",
                "es_javier_neutral": "b0346055-3824-4a72-829f-1f651d7d036a"
            ],
            "it": [
                "it_giovanni_neutral": "c0346055-3824-4a72-829f-1f651d7d036b",
                "it_isabella_neutral": "d0346055-3824-4a72-829f-1f651d7d036c"
            ]
        ]
    }
    
    /// Get available models for STT and TTS
    public static func getAvailableModels() -> [String: [String]] {
        return [
            "stt": [
                "voxtral-mini-latest",
                "voxtral-small-latest",
                "voxtral-medium-latest"
            ],
            "tts": [
                "voxtral-mini-tts-latest",
                "voxtral-small-tts-latest",
                "voxtral-medium-tts-latest"
            ]
        ]
    }
}

// MARK: - Convenience Extensions

public extension MistralAI {
    func transcribe(audioData: Data) async throws -> String {
        return try await transcribe(
            audioData: audioData,
            fileName: "audio.wav",
            language: nil,
            model: nil,
            temperature: nil,
            prompt: nil
        )
    }

    func synthesize(text: String) async throws -> Data {
        return try await synthesize(
            text: text,
            model: nil,
            voiceID: nil,
            language: nil,
            outputFormat: nil,
            speed: nil,
            temperature: nil
        )
    }
}

// MARK: - Chat Completions (text, vision, and tool/function calling)
//
// Used by the "Hi Luma" demo (see HiLumaDemo.swift) to reproduce the parts of the assistant
// pipeline that plain STT/TTS can't cover on their own: deciding WHAT to do with a transcribed
// utterance (answer directly, or call a "tool" like get_current_time/take_photo), and describing
// a captured photo (vision). This talks to Mistral's `/v1/chat/completions` endpoint, which is
// OpenAI-compatible: messages have a role + content, and `tools` are described as JSON-schema
// functions the model can choose to "call" instead of answering directly.

public extension MistralAI {

    /// One message in a chat completion conversation.
    struct ChatMessage {
        public enum ContentPart {
            case text(String)
            case imageURL(String)  // "data:image/jpeg;base64,..." or a remote https URL
        }
        public enum Content {
            case text(String)
            case parts([ContentPart])
        }

        public var role: String        // "system" | "user" | "assistant" | "tool"
        public var content: Content
        public var toolCallId: String? // only meaningful for role == "tool"
        /// When set, this message is serialized EXACTLY as this dictionary instead of from
        /// `role`/`content` above — used to echo the model's own tool-call message back
        /// verbatim in a follow-up turn (the API requires the original assistant tool_calls
        /// message to precede the matching "tool" result messages).
        public var rawOverride: [String: Any]?

        public static func system(_ text: String) -> ChatMessage {
            ChatMessage(role: "system", content: .text(text), toolCallId: nil, rawOverride: nil)
        }
        public static func user(_ text: String) -> ChatMessage {
            ChatMessage(role: "user", content: .text(text), toolCallId: nil, rawOverride: nil)
        }
        public static func userWithImage(text: String, imageDataURL: String) -> ChatMessage {
            ChatMessage(role: "user", content: .parts([.text(text), .imageURL(imageDataURL)]),
                        toolCallId: nil, rawOverride: nil)
        }
        public static func toolResult(toolCallId: String, text: String) -> ChatMessage {
            ChatMessage(role: "tool", content: .text(text), toolCallId: toolCallId, rawOverride: nil)
        }
        /// Re-inserts a previous `ChatCompletionResult.rawAssistantMessage` verbatim — required
        /// before any `.toolResult(...)` messages answering its tool calls.
        public static func assistantRaw(_ rawMessage: [String: Any]) -> ChatMessage {
            ChatMessage(role: "assistant", content: .text(""), toolCallId: nil, rawOverride: rawMessage)
        }
    }

    /// A callable tool exposed to the model, described as a JSON-schema function (OpenAI-style
    /// "function calling", which Mistral's chat API also implements).
    struct ToolDefinition {
        public let name: String
        public let description: String
        public let parametersJSONSchema: [String: Any]

        public init(name: String, description: String,
                    parametersJSONSchema: [String: Any] = ["type": "object", "properties": [String: Any](), "required": []]) {
            self.name = name
            self.description = description
            self.parametersJSONSchema = parametersJSONSchema
        }
    }

    /// One tool invocation the model asked for, extracted from `message.tool_calls`.
    struct ToolCall {
        public let id: String
        public let name: String
        public let argumentsJSON: String
    }

    /// Result of a chat completion turn: either a direct text answer, or one or more tool
    /// calls the caller must satisfy (by calling the tool, then re-invoking `chatCompletion`
    /// with `.assistantRaw(rawAssistantMessage)` followed by `.toolResult(...)` messages).
    struct ChatCompletionResult {
        public let text: String?
        public let toolCalls: [ToolCall]
        public let rawAssistantMessage: [String: Any]
    }

    /// Sends a chat completion request, with optional tool-calling and optional image content
    /// (for vision-capable models). Model choice matters here — check Mistral's current model
    /// list for which models support tool calling vs. vision, since this varies by model and
    /// may change over time.
    func chatCompletion(
        messages: [ChatMessage], tools: [ToolDefinition] = [], model: String
    ) async throws -> ChatCompletionResult {
        let endpoint = "\(currentConfig.baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw MistralError.unknownError("Invalid URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(currentConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var jsonMessages: [[String: Any]] = []
        for message in messages {
            if let raw = message.rawOverride {
                jsonMessages.append(raw)
                continue
            }
            var entry: [String: Any] = ["role": message.role]
            switch message.content {
            case .text(let text):
                entry["content"] = text
            case .parts(let parts):
                entry["content"] = parts.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): return ["type": "text", "text": text]
                    case .imageURL(let urlString): return ["type": "image_url", "image_url": urlString]
                    }
                }
            }
            if let toolCallId = message.toolCallId {
                entry["tool_call_id"] = toolCallId
            }
            jsonMessages.append(entry)
        }

        var body: [String: Any] = ["model": model, "messages": jsonMessages]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersJSONSchema
                    ]
                ]
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw MistralError.unknownError("Failed to encode chat request: \(error.localizedDescription)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralError.unknownError("Invalid response")
        }
        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw MistralError.invalidAPIKey
        case 429:
            throw MistralError.rateLimitExceeded
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MistralError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw MistralError.decodingError(NSError(domain: "MistralAI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected chat completion response shape"]))
        }

        let text = message["content"] as? String
        var toolCalls: [ToolCall] = []
        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            for rawCall in rawToolCalls {
                guard let id = rawCall["id"] as? String,
                      let function = rawCall["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let argumentsJSON = function["arguments"] as? String ?? "{}"
                toolCalls.append(ToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
            }
        }

        return ChatCompletionResult(text: text, toolCalls: toolCalls, rawAssistantMessage: message)
    }

    /// Convenience for a one-shot vision question (no tool calling, no conversation history):
    /// describes `imageData` (a JPEG) per `prompt` using a vision-capable model.
    func describeImage(
        imageData: Data, prompt: String, model: String = "pixtral-12b-latest"
    ) async throws -> String {
        let base64 = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64)"
        let result = try await chatCompletion(
            messages: [.userWithImage(text: prompt, imageDataURL: dataURL)],
            tools: [], model: model
        )
        guard let text = result.text else {
            throw MistralError.unknownError("Vision model returned no text content")
        }
        return text
    }
}
