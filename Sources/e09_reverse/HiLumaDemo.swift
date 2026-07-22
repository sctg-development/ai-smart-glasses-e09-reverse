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

// MARK: - "Hi Luma" end-to-end demo
//
// Reproduces, using Mistral AI instead of any vendor-specific cloud backend, the kind of
// voice-assistant behavior these glasses are designed for, e.g.:
//   "Hi Luma, quelle heure est-il ?"              -> spoken current time
//   "Hi Luma, qu'est-ce que je regarde ?"          -> takes a photo, describes the scene
//   "Hi Luma, prends une photo"                    -> takes a photo, no description
//   "Hi Luma, comment dit-on montre en anglais ?"  -> direct answer (translation), no tool
//
// Pipeline: real wake-word listen (validatePassiveWakeWordListen's capture logic, reused) ->
// Mistral STT (already wired into finishAudioCapture) -> Mistral chat completion with 3 tools
// -> tool execution (BLE commands) or direct answer -> Mistral TTS -> playback via `afplay`.
//
// Requires MISTRAL_API_KEY in the environment. MISTRAL_LANGUAGE is optional (defaults to "fr").
//
// Model choice: Mistral's model catalog changes over time — if `chatModel`/`visionModel` below
// are no longer valid model names when you run this, check Mistral's current model list and
// update the constants (they are deliberately NOT hardcoded anywhere else in this file).
private let hiLumaChatModel = "mistral-small-latest"
private let hiLumaVisionModel = "ministral-14b-latest"

extension BleProbe {

    /// Main entry point for the "Hi Luma" demo — a single real wake-word utterance, end to end.
    func validateHiLumaDemo() async -> Bool {
        guard let apiKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"], !apiKey.isEmpty else {
            print("[hiLumaDemo] MISTRAL_API_KEY is not set in the environment — aborting")
            return false
        }

        print("""

        [hiLumaDemo] This demo listens for a REAL, physically-spoken "Hi Luma" (nothing is sent
        over BLE to trigger it), transcribes what you say with Mistral AI, decides what to do
        about it, and speaks a reply back through this Mac's speaker.

        WHAT TO DO BEFORE YOU PRESS ENTER:
          1. Get ready to say "Hi Luma" to the glasses OUT LOUD, ALONE — do not say your question
             at the same time. The glasses need a clean, isolated "Hi Luma" to recognize it.
          2. Listening starts the INSTANT you press enter below.
          3. WAIT for the wake-word beep, THEN ask one of:
               "Quelle heure est-il ?"
               "Qu'est-ce que je regarde ?"
               "Prends une photo"
               "Comment dit-on montre en anglais ?"
             (or any similar question — the assistant will do its best with anything you ask)
          4. After you finish speaking, just go quiet and wait — the demo detects the end of
             your sentence from a silence gap (or a 20s safety cap).
        """)
        print("[hiLumaDemo] Press enter when ready to start listening...")
        _ = readLine()

        _ = await probeForAudioStreamAdaptive(
            label: "hiLumaDemo", quietGapSeconds: 2.5, maxDuration: 20.0, sendStopCommandOnVADSilence: true
        )

        guard let transcript = lastTranscribedText, !transcript.isEmpty else {
            print("[hiLumaDemo] No transcription available (no speech captured, or MISTRAL_API_KEY " +
                  "rejected/failed) — aborting")
            return false
        }
        print("[hiLumaDemo] You said: \"\(transcript)\"")

        let mistral: MistralAI
        do {
            mistral = try MistralAI(config: .init(apiKey: apiKey))
        } catch {
            print("[hiLumaDemo] Could not initialize MistralAI: \(error.localizedDescription)")
            return false
        }

        // MISTRAL_LANGUAGE (optional, defaults to "fr") picks both the reply language and the
        // TTS voice used for playback below — set it to "en"/"es"/"de"/"it" to get a localized
        // assistant instead of the French default.
        let language = ProcessInfo.processInfo.environment["MISTRAL_LANGUAGE"] ?? "fr"
        let languageNameInFrench = [
            "fr": "français", "en": "anglais", "es": "espagnol", "de": "allemand", "it": "italien"
        ][language] ?? "la langue de code \"\(language)\""

        let systemPrompt = """
        Tu es Luma, l'assistant vocal intégré à des lunettes connectées. Réponds toujours en \
        \(languageNameInFrench), en une ou deux phrases courtes et naturelles, comme si tu parlais \
        à voix haute (pas de listes, pas de markdown). Si on te demande l'heure, appelle l'outil \
        get_current_time. Si on te demande de prendre une photo SANS description, appelle \
        take_photo_only. Si on te demande ce que l'utilisateur regarde, voit, ou une description \
        de la scène/pièce, appelle describe_what_i_see. Pour toute autre question (traduction, \
        culture générale, conversation), réponds directement sans appeler d'outil.
        """

        let tools: [MistralAI.ToolDefinition] = [
            .init(name: "get_current_time", description: "Donne l'heure actuelle."),
            .init(name: "take_photo_only", description: "Prend une photo sans la décrire."),
            .init(name: "describe_what_i_see", description: "Prend une photo et décrit la scène/les objets visibles.")
        ]

        do {
            let firstTurn = try await mistral.chatCompletion(
                messages: [.system(systemPrompt), .user(transcript)],
                tools: tools, model: hiLumaChatModel
            )

            let replyText: String
            if let toolCall = firstTurn.toolCalls.first {
                print("[hiLumaDemo] Assistant wants to call: \(toolCall.name)")
                replyText = try await runHiLumaTool(
                    toolCall: toolCall, transcript: transcript, mistral: mistral,
                    systemPrompt: systemPrompt, previousUserMessage: transcript,
                    rawAssistantMessage: firstTurn.rawAssistantMessage
                )
            } else if let text = firstTurn.text, !text.isEmpty {
                replyText = text
            } else {
                replyText = "Désolé, je n'ai pas compris."
            }

            print("[hiLumaDemo] Luma: \(replyText)")
            await speakAndPlay(replyText, language: language, using: mistral)
            return true
        } catch {
            print("[hiLumaDemo] Error during chat completion: \(error.localizedDescription)")
            return false
        }
    }

    /// Executes the tool the model asked for, then returns the final natural-language reply to
    /// speak back. `get_current_time`/`take_photo_only` feed their result back to the model for
    /// a second turn (so the phrasing stays natural); `describe_what_i_see` asks the vision
    /// model directly and uses its answer as-is (no need for a second text-model round trip).
    private func runHiLumaTool(
        toolCall: MistralAI.ToolCall, transcript: String, mistral: MistralAI, systemPrompt: String,
        previousUserMessage: String, rawAssistantMessage: [String: Any]
    ) async throws -> String {
        switch toolCall.name {
        case "get_current_time":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "HH:mm"
            let timeString = formatter.string(from: Date())
            return try await finishToolCallWithFollowUp(
                toolCall: toolCall, resultText: "Il est \(timeString).", mistral: mistral,
                systemPrompt: systemPrompt, previousUserMessage: previousUserMessage,
                rawAssistantMessage: rawAssistantMessage
            )

        case "take_photo_only":
            print("[hiLumaDemo] Taking photo (TAKE_PHOTO)...")
            let photoOK = validateTakePhoto()
            let resultText = photoOK
                ? "Photo prise avec succès (\(photoBuffer.count) octets)."
                : "La prise de photo a échoué."
            return try await finishToolCallWithFollowUp(
                toolCall: toolCall, resultText: resultText, mistral: mistral,
                systemPrompt: systemPrompt, previousUserMessage: previousUserMessage,
                rawAssistantMessage: rawAssistantMessage
            )

        case "describe_what_i_see":
            print("[hiLumaDemo] Taking photo (TAKE_PHOTO) for description...")
            guard validateTakePhoto(), !photoBuffer.isEmpty else {
                return "Je n'ai pas réussi à prendre de photo."
            }
            print("[hiLumaDemo] Asking the vision model to describe the scene...")
            return try await mistral.describeImage(
                imageData: photoBuffer,
                prompt: "Décris en français, en une ou deux phrases naturelles et orales, les " +
                        "objets et la scène visibles sur cette photo, comme si tu répondais à la " +
                        "question : « \(transcript) »",
                model: hiLumaVisionModel
            )

        default:
            return "Je ne sais pas comment faire ça."
        }
    }

    /// Shared by get_current_time/take_photo_only: feeds the tool's result back to the model
    /// (re-inserting its own tool-call message first, as the chat API requires) so the FINAL
    /// reply is phrased naturally rather than read back as a raw template string.
    private func finishToolCallWithFollowUp(
        toolCall: MistralAI.ToolCall, resultText: String, mistral: MistralAI, systemPrompt: String,
        previousUserMessage: String, rawAssistantMessage: [String: Any]
    ) async throws -> String {
        let followUp = try await mistral.chatCompletion(
            messages: [
                .system(systemPrompt),
                .user(previousUserMessage),
                .assistantRaw(rawAssistantMessage),
                .toolResult(toolCallId: toolCall.id, text: resultText)
            ],
            tools: [], model: hiLumaChatModel
        )
        return followUp.text ?? resultText
    }

    /// Synthesizes `text` via Mistral TTS — using a voice matched to `language` when one is
    /// available (falls back to MistralAI's own default voice otherwise) — and plays it back
    /// using `afplay` (ships with macOS — simpler and more robust here than wiring up
    /// AVFoundation for a one-shot playback, and works regardless of the returned audio
    /// container/codec). `afplay` plays through the system's current default audio OUTPUT
    /// device — if the glasses are paired as a standard Bluetooth audio device (separate from
    /// the BLE GATT connection this tool otherwise uses) and selected as that output, this is
    /// what actually gets the reply to play through the glasses' speaker.
    private func speakAndPlay(_ text: String, language: String, using mistral: MistralAI) async {
        do {
            // Note: the /v1/audio/speech endpoint does NOT accept a `language` field (rejected
            // with a 422 "extra_forbidden" error) — the chosen voice already encodes the
            // language, so only voiceID is passed here (unlike /v1/audio/transcriptions, which
            // does take a `language` parameter and is used that way in finishAudioCapture).
            let voiceID = MistralAI.getAvailableVoices()[language]?.values.first
            let audioData = try await mistral.synthesize(text: text, voiceID: voiceID)

            // The API's actual returned container is unconfirmed (output_format is deliberately
            // not requested, see MistralAI.synthesize) — naming the file ".mp3" unconditionally
            // previously caused afplay to fail with "AudioFileOpen failed ('dta?')" when the
            // real content wasn't MP3. Sniff the magic bytes and use a matching extension instead.
            let ext = audioFileExtension(for: audioData)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hiLumaDemo_reply_\(UUID().uuidString).\(ext)")
            try audioData.write(to: tempURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [tempURL.path]
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                print("[hiLumaDemo] ⚠️ afplay exited with status \(process.terminationStatus) — " +
                      "kept the file for inspection: \(tempURL.path) (\(audioData.count) bytes, " +
                      "detected extension: .\(ext))")
            }
        } catch {
            print("[hiLumaDemo] Could not synthesize/play the reply: \(error.localizedDescription)")
        }
    }

    /// Detects the audio container from its magic bytes so the temp file gets an extension that
    /// actually matches its content — CoreAudio/afplay can fail outright ("AudioFileOpen failed")
    /// when a file's extension doesn't match its real format. Falls back to "mp3" (the
    /// configured default, see MistralAI.Config.ttsOutputFormat) if nothing recognizable matches.
    private func audioFileExtension(for data: Data) -> String {
        guard data.count >= 12 else { return "mp3" }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 { return "wav" }   // "RIFF"
        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { return "ogg" }   // "OggS"
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return "flac" }  // "fLaC"
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return "mp3" }                     // "ID3"
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "mp3" }                               // MPEG frame sync
        return "mp3"
    }
}
