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

import CoreBluetooth
import Foundation

public final class BleProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var connectingPeripheral: CBPeripheral?
    var seenIdentifiers = Set<UUID>()
    
    // Test execution configuration
    let specificTestNames: [String]?
    
    // Output mode for this instance
    let outputMode: OutputMode
    
    // Target name to search for
    let targetName: String
    
    // Notification counter for light output mode
    var notificationCount = 0
    
    // BLE characteristics for commands and notifications
    var cmdWriteCharacteristic: CBCharacteristic?
    var cmdNotifyCharacteristic: CBCharacteristic?
    var photoNotifyCharacteristic: CBCharacteristic?

    // Buffer for responses
    var responseBuffer: Data = Data()
    var expectedResponseCommandId: UInt8? = nil
    
    // Audio frame reassembly and recording. Each element is one Opus packet's raw payload bytes
    // (i.e. one APP_RECEIVE_VOICE_DATA / commandId 0x46 notification, already stripped of the
    // SOF/length/commandId/CRC framing by parseBleFrame). Packet BOUNDARIES are kept — not
    // concatenated into one blob — because muxing valid Ogg Opus requires knowing where each
    // packet starts/ends (see buildOggOpusFile below).
    var audioPackets: [[UInt8]] = []
    var isRecordingAudio = false  // Flag to track if we're currently recording audio
    var audioFileURL: URL? = nil  // URL for the current audio recording file

    // Voice-stream start/end detection (see probeForAudioStreamAdaptive /
    // validatePassiveWakeWordListen). Real hardware plays a distinct end-of-stream beep and the
    // glasses appear to keep streaming for a while after the last spoken word — this tracks
    // whether that end is signaled explicitly (a genuine CMD_VOICE_STREAM_END / commandId 153
    // notification) versus inferred from a quiet gap, and separately confirms a genuine wake-word
    // START notification (commandId 151) was actually seen (as opposed to nothing happening at all).
    var wakeWordStartMarkerSeen = false
    var voiceStreamEndMarkerSeen = false
    var lastAudioPacketAt: Date? = nil
    // Tracks the last time the VAD backend actually saw SPEECH (not just any packet arriving —
    // audio packets keep streaming continuously even during silence, so reusing
    // `lastAudioPacketAt` here would be reset on every single packet and silence would never
    // appear to last long enough). Only probeForAudioStreamAdaptive's VAD path reads/writes this.
    var lastSpeechDetectedAt: Date? = nil
    // Accumulates decoded PCM samples from newly-arrived Opus packets until there's enough for a
    // full Silero-VAD window (`vad.requiredSampleCount` — 576 samples/36ms for ONNX, 4160
    // samples/260ms for the CoreML "Unified 256ms" model). A single ~20ms BLE audio packet alone
    // is far too short: feeding it directly to `vad.isSilence(audio:)` always returned an empty
    // result (silence), regardless of actual content, which is why silence was never detected.
    var pendingVadPcm: [Float] = []
    // Index into `audioPackets` of the next packet not yet decoded into `pendingVadPcm`.
    var vadConsumedPacketIndex = 0

    // Photo frame reassembly (file-transfer protocol on UUID_PHOTO_NOTIFY, distinct framing —
    // see CMD_PHOTO_START/TRANS/END above). `isCapturingPhoto` gates parsing so diagnostic-mode
    // scans (no --validate) don't try to interpret arbitrary AA15 traffic as a photo.
    var photoBuffer: Data = Data()
    var isCapturingPhoto = false
    var expectedPhotoSize: Int? = nil
    var photoTransferComplete = false
    // Highest (offset + length) written so far — used to detect a PHOTO_TRANS chunk that
    // overlaps/duplicates data already written (see the offset-based reassembly below).
    var photoHighWaterMark: Int = 0
    let photoSemaphore = DispatchSemaphore(value: 0)

    // ACTION_SYNC passive-listen state (validateActionSyncPassiveListen)
    var isCapturingActionSync = false
    var actionSyncFramesSeen: [[UInt8]] = []

    // Set by finishAudioCapture() when MISTRAL_API_KEY/MISTRAL_LANGUAGE are configured and
    // transcription succeeds — read back by validateHiLumaDemo() after an adaptive capture.
    // Reset to nil at the top of every finishAudioCapture() call so a stale transcript from a
    // PREVIOUS capture never leaks into a run where STT was skipped or failed this time.
    var lastTranscribedText: String? = nil

    // Semaphore to synchronize responses
    let responseSemaphore = DispatchSemaphore(value: 0)
    var lastResponse: Data? = nil
    var lastError: Error? = nil
    
    // Validation tests state
    var validationTestsCompleted = false  // Flag to ensure validation tests run only once
    
    // VAD (Voice Activity Detection) components
    var vad: VoiceActivityDetector?
    var opusDecoder: OpusDecoder?
    var vadInitialized = false

    // Number of services still awaiting characteristic discovery. `didDiscoverCharacteristicsFor`
    // fires once per service, so this lets us wait until ALL services have reported back instead
    // of guessing with a fixed delay (which was also firing `runValidationTests()` redundantly,
    // once per discovered service).
    var pendingServiceCount = 0

    // CBCentralManager delegate/notification callbacks are delivered on this queue. It MUST be a
    // queue distinct from whatever thread runs the validation tests below: those tests block
    // synchronously on `responseSemaphore.wait(...)`/`Thread.sleep(...)`, and `DispatchSemaphore.wait`
    // does not pump the run loop — it just parks the thread. If CoreBluetooth were also delivering
    // `didUpdateValueFor` on that same (blocked) queue, as happens with `queue: nil` (which defaults
    // to the main queue) combined with running the tests on the main queue, every notification would
    // queue up behind the blocked test code and only get delivered once the whole test suite finishes
    // — which is exactly what the "timeout" failures traced back to in practice.
    let bleQueue = DispatchQueue(label: "com.eyevue.bleprobe.corebluetooth")
    
    // Initialize with the specific test names, output mode, and target name from command line
    init(specificTestNames: [String]? = nil, outputMode: OutputMode = .light, targetName: String = "E09") {
        self.specificTestNames = specificTestNames
        self.outputMode = outputMode
        self.targetName = targetName
        super.init()
    }

    // Test definitions with Swift function names and English descriptions
    static let allTests: [(swiftName: String, displayName: String, description: String)] = [
        // --- General tests ---
        ("validateBattery", "Battery", "Test battery level retrieval"),
        ("validateStorageCapacity", "Storage capacity", "Test storage capacity retrieval"),
        ("validateDeviceInfo", "Device info", "Test firmware version retrieval"),
        ("validateSupportFunction", "Support function bitmask", "Test hardware capability bitmask"),
        
        // --- Photo tests ---
        ("validateTakePhoto", "Take photo", "Test full high-quality photo capture + save"),
        
        // --- Audio tests ---
        ("validateVoiceCommand", "Voice command activation", "Test voice command activation"),
        ("validateVoiceAssistantStatus", "Voice assistant status", "Test wake-word/assistant status"),
        ("validateAudioRecording", "Audio recording (2s)", "Test 2-second audio recording (target is internal storage; retrievable via Wi-Fi)"),
        ("probeStartVoiceRecognition", "Audio: start voice recording", "Experimental mic-stream trigger (target is BLE)"),
        ("probeDevicePhotoRecognition", "Audio: device photo recognition", "Experimental mic-stream trigger (say \"Hi Luma\" and speak; target is BLE)"),
        ("validatePassiveWakeWordListen", "Audio: passive wake-word listen", "Real wake word, no synthetic BLE trigger — has its own detailed pre-test prompt (sends nothing; say \"Hi Luma\" yourself)"),

        // --- Extended validation tests (see VALIDATION_PLAN.md) ---
        ("validateSetVoiceAssistantStatus", "Voice assistant status set", "Toggle + restore SET_VOICE_ASSISTANT_STATUS (0x72) round-trip"),
        ("probeCancelVoiceRecognitionDuringStream", "Cancel: voice recognition during stream", "Send APP_CANCEL_VOICE_RECOGNITION (0x49) mid-stream"),
        ("probeCancelAiVoiceDuringStream", "Cancel: AI voice during stream", "Send APP_CANCEL_AI_VOICE (0x51) mid-stream"),
        ("probeOpenWifiMediaImport", "Open WiFi media import", "Trigger OPEN_WIFI (0x39) and decode SSID from APP_RECEIVE_WIFI_INFO"),
        ("validateActionSyncPassiveListen", "Action sync passive listen", "Listen for spontaneous ACTION_SYNC (0x45) notifications"),
        ("validateTakePhotoSizeConsistency", "Photo size consistency", "Verify PHOTO_START size delta is constant across captures"),

        // --- "Hi Luma" end-to-end demo (Mistral AI) ---
        ("validateHiLumaDemo", "Hi Luma demo (Mistral AI)", "Real wake word -> Mistral STT -> chat/tool routing -> photo/time/vision -> Mistral TTS playback (requires MISTRAL_API_KEY)"),
    ]

    func start() {
        print("Looking for a device whose name contains \"\(targetName)\"...")
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }
    
    // MARK: - VAD Initialization
    
    /// Runs a single dummy inference through a freshly-constructed VAD implementation to confirm
    /// it can actually execute, not just load. Some CoreML models load successfully via
    /// `MLModel(contentsOf:)` but fail at prediction time (e.g. "Unable to compute the
    /// prediction using ML Program" from the BNNS backend on Macs without a Neural Engine) —
    /// this catches that case early so callers can fall back to another backend.
    private static func verifyVADCanRunInference(_ vad: VoiceActivityDetector) throws {
        // 1 full second of audio comfortably covers any Silero VAD window size in use (576
        // samples for the classic 32ms ONNX model, 4160 samples for the 256ms CoreML model).
        let warmupSamples = [Float](repeating: 0.0, count: vad.sampleRate)
        _ = try vad.isSilence(audio: warmupSamples)
        vad.reset()
    }
    
    /// Initialize Voice Activity Detection with Silero-VAD model
    private func initializeVAD() {
        guard !vadInitialized else { return }
        
        do {
            // Try CoreML first (optimized for macOS)
            // Look for models in bundle resources first, then fallback to current directory
            var coreMLModelPath: URL? = nil
            var onnxModelPath: URL? = nil
            
            // Check in bundle resources (where SPM copies resources)
            if let bundleResourceURL = Bundle.main.resourceURL {
                let coreMLPath = bundleResourceURL
                    .appendingPathComponent("silero-vad.mlmodelc")
                if FileManager.default.fileExists(atPath: coreMLPath.path) {
                    coreMLModelPath = coreMLPath
                }
                
                let onnxPath = bundleResourceURL
                    .appendingPathComponent("silero_vad.onnx")
                if FileManager.default.fileExists(atPath: onnxPath.path) {
                    onnxModelPath = onnxPath
                }
            }
            
            // Fallback: check in current directory Resources folder
            if coreMLModelPath == nil || onnxModelPath == nil {
                let currentDirResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Resources")
                
                if coreMLModelPath == nil {
                    let path = currentDirResources.appendingPathComponent("silero-vad.mlmodelc")
                    if FileManager.default.fileExists(atPath: path.path) {
                        coreMLModelPath = path
                    }
                }
                
                if onnxModelPath == nil {
                    let path = currentDirResources.appendingPathComponent("silero_vad.onnx")
                    if FileManager.default.fileExists(atPath: path.path) {
                        onnxModelPath = path
                    }
                }
            }
            
            // Try CoreML first, but gracefully fall back to ONNX if the CoreML model fails to
            // load (e.g. an unresolved Git LFS pointer instead of real weights) OR fails to
            // actually run inference (observed on Intel Macs without a Neural Engine: the model
            // loads fine but BNNS — CoreML's CPU/GPU execution backend — cannot execute this
            // particular ML Program, throwing "Unable to compute the prediction using ML
            // Program" at prediction time rather than at load time).
            if let coreMLPath = coreMLModelPath {
                do {
                    let coreMLVAD = try CoreMLSileroVAD(modelPath: coreMLPath, sampleRate: 16000, threshold: 0.5)
                    try Self.verifyVADCanRunInference(coreMLVAD)
                    vad = coreMLVAD
                    print("[VAD] Initialized with CoreML model")
                } catch {
                    print("[VAD] CoreML model failed to load or run (\(error.localizedDescription)); trying ONNX fallback")
                }
            }
            
            if vad == nil, let onnxPath = onnxModelPath {
                vad = try ONNXSileroVAD(modelPath: onnxPath, sampleRate: 16000, threshold: 0.5)
                print("[VAD] Initialized with ONNX Runtime")
            }
            
            if vad == nil {
                print("[VAD] No usable VAD model found (CoreML or ONNX). Falling back to packet-based silence detection.")
            }
            
            // Initialize Opus decoder
            opusDecoder = try OpusDecoder(sampleRate: 16000, channelCount: 1)
            print("[VAD] Opus decoder initialized")
            
            vadInitialized = true
            
        } catch {
            print("[VAD] Initialization failed: \(error.localizedDescription)")
        }
    }

    // Helper function to display notification data based on output mode
    func displayNotification(_ value: Data, on characteristic: CBCharacteristic, prefix: String = "[notification]") {
        notificationCount += 1
        
        let bytes = [UInt8](value)
        
        switch outputMode {
        case .light:
            print(".", terminator: "")
            if notificationCount % 20 == 0 {
                print() // New line every 20 notifications
            }
        case .normal:
            // Truncated output (20 bytes max)
            if bytes.count <= 20 {
                let hexString = bytes.map { String(format: "0x%02X", $0) }.joined(separator: " ")
                print("\(prefix) Received \(bytes.count) bytes on \(characteristic.uuid.uuidString): \(hexString)")
            } else {
                let truncated = bytes.prefix(20).map { String(format: "0x%02X", $0) }.joined(separator: " ")
                print("\(prefix) Received \(bytes.count) bytes on \(characteristic.uuid.uuidString): \(truncated)... (truncated)")
            }
        case .debug:
            // Full output
            let hexString = bytes.map { String(format: "0x%02X", $0) }.joined(separator: " ")
            print("\(prefix) Received \(bytes.count) bytes on \(characteristic.uuid.uuidString): \(hexString)")
        }
    }
    
    // MARK: - BLE Frame Construction Functions
    
    func buildBleFrame(commandId: UInt8, payload: [UInt8]? = nil) -> Data {
        let payloadBytes = payload ?? []
        let length = 1 + payloadBytes.count + 1
        
        var frame = Data()
        frame.append(SOF_APP_BLE, count: 2)
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(commandId)
        
        if !payloadBytes.isEmpty {
            frame.append(contentsOf: payloadBytes)
        }
        
        var crc: UInt8 = commandId
        for byte in payloadBytes {
            crc = crc &+ byte
        }
        frame.append(crc)
        
        return frame
    }
    
    func parseBleFrame(data: Data) -> (commandId: UInt8, payload: [UInt8], crc: UInt8)? {
        guard data.count >= 6 else {
            print("[parseBleFrame] Frame too short: \(data.count) bytes")
            return nil
        }
        
        let bytes = [UInt8](data)
        let sof = [bytes[0], bytes[1]]
        if sof != SOF_BLE_APP {
            print("[parseBleFrame] Invalid SOF: \(sof.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
            return nil
        }
        
        let _ = Int(bytes[2]) << 8 | Int(bytes[3]) // Length (not used yet)
        let commandId = bytes[4]
        let payloadStart = 5
        let payloadEnd = data.count - 1
        let payloadCount = payloadEnd - payloadStart
        var payload: [UInt8] = []
        if payloadCount > 0 {
            payload = Array(bytes[payloadStart..<payloadEnd])
        }
        
        let receivedCrc = bytes[data.count - 1]
        var calculatedCrc: UInt8 = commandId
        for byte in payload {
            calculatedCrc = calculatedCrc &+ byte
        }
        
        if receivedCrc != calculatedCrc {
            print("[parseBleFrame] Invalid CRC: received=0x\(String(format: "%02X", receivedCrc)), calculated=0x\(String(format: "%02X", calculatedCrc))")
            return nil
        }
        
        return (commandId, payload, receivedCrc)
    }

    /// Drains any stale signal(s) left on `responseSemaphore` by a PREVIOUS test's late-arriving,
    /// unconsumed notification (e.g. VOICE_COMMAND's own echo — `validateVoiceCommand` doesn't wait
    /// for it — or a trailing ACTION_SYNC/thumbnail-count push after a photo transfer). Every test
    /// below that does `expectedResponseCommandId = X; ...; responseSemaphore.wait(...)` must call
    /// this first: without it, a leftover signal makes that `wait()` return immediately with
    /// `lastResponse` still holding the PREVIOUS test's data, misreported as "Unexpected or
    /// unparseable response" (observed on real hardware: a stale VOICE_COMMAND echo caused the very
    /// next "Voice assistant status" test to spuriously fail this way).
    func drainStaleResponseSignal() {
        while responseSemaphore.wait(timeout: .now()) == .success {
            // Just discard — the new command's own response will (re)populate lastResponse once
            // it actually arrives and gets matched against the freshly-set expectedResponseCommandId.
        }
        lastResponse = nil
        lastError = nil
    }

    /// Parses a file-transfer protocol frame (PHOTO_START/PHOTO_TRANS/PHOTO_END) as received on
    /// UUID_PHOTO_NOTIFY. This is a DIFFERENT wire format from `parseBleFrame` above: SOF is
    /// 0x52 0x58 (not 0xAC 0x55), and the frame ends with a 2-byte trailing footer 0x58 0x52
    /// (a repeat of the SOF bytes, reversed) after the CRC — confirmed by real hardware capture.
    /// Layout: [0x52,0x58][len:2][commandId:1][payload:n][crc:1][0x58,0x52].
    func parseFileFrame(data: Data) -> (commandId: UInt8, payload: [UInt8])? {
        // Minimum: 2 (SOF) + 2 (len) + 1 (commandId) + 1 (crc) + 2 (footer) = 8 bytes
        guard data.count >= 8 else { return nil }

        let bytes = [UInt8](data)
        guard bytes[0] == 0x52, bytes[1] == 0x58 else { return nil }

        let commandId = bytes[4]
        let crcIndex = bytes.count - 3  // 2 footer bytes follow the CRC
        guard crcIndex >= 5 else { return nil }
        let payload = Array(bytes[5..<crcIndex])
        return (commandId, payload)
    }

    // MARK: - Validation Functions
    // These functions test the various features of the Eyevue glasses by sending specific BLE commands
    // and validating the responses according to the protocol specification.
    
    /// Validates the battery level and charging status of the Eyevue glasses
    /// - Returns: true if battery information was successfully retrieved and parsed, false otherwise
    /// This test sends the GET_BATTERY command (0x17) with PARAM_BATTERY_CAPACITY parameter (0x00)
    /// and expects a response containing:
    /// - 2 bytes for battery level in BCD format (tens and units digits)
    /// - 1 optional byte for charging status (1 = charging, 0 = not charging)
    /// Example response: [0xAC, 0x55, 0x00, 0x03, 0x17, 0x25, 0x01] = 25% battery, charging
    func validateBattery() -> Bool {
        print("[validateBattery] Retrieving battery level...")
        
        // Build the GET_BATTERY command frame with PARAM_BATTERY_CAPACITY parameter
        let frame = buildBleFrame(commandId: CMD_GET_BATTERY, payload: [PARAM_BATTERY_CAPACITY])
        print("[validateBattery] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Verify we have a connected peripheral and the command write characteristic
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateBattery] Device or characteristic not available")
            return false
        }
        
        // Check if the characteristic supports write operations
        if characteristic.properties.contains(.write) {
            // Set expected response command ID to filter notifications
            drainStaleResponseSignal()
            expectedResponseCommandId = CMD_GET_BATTERY
            
            // Send the command to the glasses
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
            
            let timeout = DispatchTime.now() + .seconds(5)
            let waitResult = responseSemaphore.wait(timeout: timeout)
            
            // Clear expected command ID after timeout or response
            expectedResponseCommandId = nil
            
            if waitResult == .timedOut {
                print("[validateBattery] Timeout waiting for response")
                return false
            }
            
            if let error = lastError {
                print("[validateBattery] Error: \(error.localizedDescription)")
                lastError = nil
                return false
            }
            
            // Process the received response
            if let responseData = lastResponse {
                lastResponse = nil
                // Parse the BLE frame from the raw response data
                if let parsedFrame = parseBleFrame(data: responseData) {
                    let (commandId, payload, _) = parsedFrame
                    
                    // Validate that we received the expected response
                    if commandId == CMD_GET_BATTERY && payload.count >= 2 {
                        // Parse battery level from BCD format (2 bytes: tens and units)
                        // Example: [0x02, 0x05] = 25% battery
                        let batteryValue = ((payload[0] & 0x0F) * 10) + (payload[1] & 0x0F)
                        // Parse charging status if present (3rd byte: 1 = charging, 0 = not charging)
                        let isCharging = payload.count >= 3 ? payload[2] == 1 : false
                        
                        print("[validateBattery] ✅ Battery level: \(batteryValue)% (is charging: \(isCharging ? "yes" : "no"))")
                        return true
                    } else {
                        // Unexpected command ID or payload format
                        print("[validateBattery] Unexpected response: commandId=0x\(String(format: "%02X", commandId))")
                        return false
                    }
                } else {
                    // Failed to parse the BLE frame (invalid SOF or CRC)
                    print("[validateBattery] Failure to parse response frame")
                    return false
                }
            } else {
                // No response was received
                print("[validateBattery] No response received")
                return false
            }
        } else {
            // Characteristic doesn't support write operations
            print("[validateBattery] [characteristic is not writable]")
            return false
        }
    }
    
    /// Validates the storage capacity of the Eyevue glasses
    /// - Returns: true if storage capacity information was successfully retrieved and parsed, false otherwise
    /// This test sends the GET_CAPACITY command (0x16) with PARAM_BATTERY_CAPACITY parameter (0x00)
    /// and expects a response containing a big-endian integer. Real hardware has been observed
    /// replying with a 2-byte payload (not 4 as originally assumed) — the unit/scale of that
    /// integer is not yet confirmed, so it's decoded generically and reported as a raw value.
    /// Example response observed on real hardware: [0xAC, 0x55, 0x00, 0x04, 0x16, 0x00, 0x01, 0x17]
    func validateStorageCapacity() -> Bool {
        print("[validateStorageCapacity] Retrieving storage capacity...")
        
        // Build the GET_CAPACITY command frame with PARAM_BATTERY_CAPACITY parameter
        let frame = buildBleFrame(commandId: CMD_GET_CAPACITY, payload: [PARAM_BATTERY_CAPACITY])
        print("[validateStorageCapacity] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Verify we have a connected peripheral and the command write characteristic
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateStorageCapacity] Device or characteristic not available")
            return false
        }
        
        // Check if the characteristic supports write operations
        if characteristic.properties.contains(.write) {
            // Set expected response command ID to filter notifications
            drainStaleResponseSignal()
            expectedResponseCommandId = CMD_GET_CAPACITY
            
            // Send the command to the glasses
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
            
            // Wait for response with a 5-second timeout
            let timeout = DispatchTime.now() + .seconds(5)
            let waitResult = responseSemaphore.wait(timeout: timeout)
            
            // Clear expected command ID after timeout or response
            expectedResponseCommandId = nil
            
            // Handle timeout case
            if waitResult == .timedOut {
                print("[validateStorageCapacity] Timeout waiting for response")
                return false
            }
            
            // Handle any errors that occurred during the operation
            if let error = lastError {
                print("[validateStorageCapacity] Error: \(error.localizedDescription)")
                lastError = nil
                return false
            }
            
            // Process the received response
            if let responseData = lastResponse {
                lastResponse = nil
                // Parse the BLE frame from the raw response data
                if let parsedFrame = parseBleFrame(data: responseData) {
                    let (commandId, payload, _) = parsedFrame
                    
                    // Validate that we received the expected response
                    if commandId == CMD_GET_CAPACITY {
                        // Real hardware (captured 2026-07-17) actually replies with a 2-byte
                        // big-endian payload (e.g. [0x00, 0x01]), not the originally assumed 4
                        // bytes — decode whatever big-endian width we actually got instead of
                        // requiring exactly 4, so this doesn't spuriously fail against real
                        // devices. The unit/scale of the resulting integer is not yet confirmed
                        // (raw bytes? blocks? some other unit) — reported as-is.
                        if payload.count >= 2 {
                            let capacity = payload.reduce(0) { ($0 << 8) | Int($1) }
                            print("[validateStorageCapacity] ✅ Storage capacity raw value: \(capacity) " +
                                  "(\(payload.count)-byte big-endian payload; unit not confirmed)")
                            return true
                        } else {
                            // Payload too short to contain capacity information
                            print("[validateStorageCapacity] Payload too short to decode capacity")
                            return false
                        }
                    } else {
                        // Unexpected command ID
                        print("[validateStorageCapacity] Unexpected response: commandId=0x\(String(format: "%02X", commandId))")
                        return false
                    }
                } else {
                    // Failed to parse the BLE frame (invalid SOF or CRC)
                    print("[validateStorageCapacity] Failure to parse response frame")
                    return false
                }
            } else {
                // No response was received
                print("[validateStorageCapacity] No response received")
                return false
            }
        } else {
            // Characteristic doesn't support write operations
            print("[validateStorageCapacity] [characteristic is not writable]")
            return false
        }
    }
    
    /// Validates retrieval of firmware version info.
    /// - Returns: true if the BT/ISP/device firmware versions were successfully retrieved, false otherwise
    /// Sends GET_DEVICE_INFO (0x55) with a zero parameter and decodes the response:
    /// btVersion = bytes[0].bytes[1].bytes[2],
    /// ispVersion = bytes[3].bytes[4].bytes[5], deviceVersion = bytes[6].
    func validateDeviceInfo() -> Bool {
        print("[validateDeviceInfo] Retrieving firmware version info...")

        let frame = buildBleFrame(commandId: CMD_GET_DEVICE_INFO, payload: [0x00])
        print("[validateDeviceInfo] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateDeviceInfo] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[validateDeviceInfo] [characteristic is not writable]")
            return false
        }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_GET_DEVICE_INFO
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(5))
        expectedResponseCommandId = nil

        if waitResult == .timedOut {
            print("[validateDeviceInfo] Timeout waiting for response")
            return false
        }
        if let error = lastError {
            print("[validateDeviceInfo] Error: \(error.localizedDescription)")
            lastError = nil
            return false
        }
        guard let responseData = lastResponse else {
            print("[validateDeviceInfo] No response received")
            return false
        }
        lastResponse = nil

        guard let parsedFrame = parseBleFrame(data: responseData), parsedFrame.commandId == CMD_GET_DEVICE_INFO else {
            print("[validateDeviceInfo] Unexpected or unparseable response")
            return false
        }
        let payload = parsedFrame.payload
        guard payload.count >= 7 else {
            print("[validateDeviceInfo] Payload too short to decode versions (\(payload.count) bytes)")
            return false
        }

        let btVersion = "\(payload[0]).\(payload[1]).\(payload[2])"
        let ispVersion = "\(payload[3]).\(payload[4]).\(payload[5])"
        let deviceVersion = "\(payload[6])"
        print("[validateDeviceInfo] ✅ btVersion=\(btVersion) ispVersion=\(ispVersion) deviceVersion=\(deviceVersion)")
        return true
    }

    /// Validates retrieval of the device's hardware capability bitmask.
    /// - Returns: true if the capability bitmask was successfully retrieved and decoded, false otherwise
    /// Sends GET_SUPPORT_FUNCTION (0x95) and decodes the 4-byte big-endian capability bitmask —
    /// notably bit 7 (AI wake-word support), directly relevant to the "Hi Luma" wake-word
    /// investigation.
    func validateSupportFunction() -> Bool {
        print("[validateSupportFunction] Retrieving device capability bitmask...")

        let frame = buildBleFrame(commandId: CMD_GET_SUPPORT_FUNCTION, payload: [0x00])
        print("[validateSupportFunction] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateSupportFunction] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[validateSupportFunction] [characteristic is not writable]")
            return false
        }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_GET_SUPPORT_FUNCTION
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(5))
        expectedResponseCommandId = nil

        if waitResult == .timedOut {
            print("[validateSupportFunction] Timeout waiting for response")
            return false
        }
        if let error = lastError {
            print("[validateSupportFunction] Error: \(error.localizedDescription)")
            lastError = nil
            return false
        }
        guard let responseData = lastResponse else {
            print("[validateSupportFunction] No response received")
            return false
        }
        lastResponse = nil

        guard let parsedFrame = parseBleFrame(data: responseData), parsedFrame.commandId == CMD_GET_SUPPORT_FUNCTION else {
            print("[validateSupportFunction] Unexpected or unparseable response")
            return false
        }
        let payload = parsedFrame.payload
        guard payload.count >= 4 else {
            print("[validateSupportFunction] Payload too short to decode capabilities (\(payload.count) bytes)")
            return false
        }

        let mask: UInt32 = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
            | (UInt32(payload[2]) << 8) | UInt32(payload[3])
        let capabilities: [(bit: Int, name: String)] = [
            (0, "live"), (1, "quickVolume"), (2, "photoWatermark"), (3, "wearDetectionDynamic"),
            (4, "wearDetection"), (5, "stabilizationDynamic"), (6, "stabilization"),
            (7, "aiWakeWord"), (8, "localOfflineVoice"), (9, "dynamicLanguageSwitch"),
            (10, "screenOrientationDynamic"), (11, "screenOrientation"), (12, "independentFactoryResetButton"),
        ]
        print("[validateSupportFunction] ✅ Capability bitmask: 0x\(String(format: "%08X", mask))")
        for (bit, name) in capabilities {
            let supported = (mask & (1 << bit)) != 0
            print("    - \(name) (bit \(bit)): \(supported ? "yes" : "no")")
        }
        return true
    }

    /// Validates retrieval of the voice-assistant/wake-word status.
    /// - Returns: true if the status was successfully retrieved and decoded, false otherwise
    /// Sends GET_VOICE_ASSISTANT_STATUS (0x71) and decodes the status byte. Note: the bits
    /// are inverted — a bit of `0` means the corresponding feature is ACTIVE, not `1`.
    func validateVoiceAssistantStatus() -> Bool {
        print("[validateVoiceAssistantStatus] Retrieving voice assistant status...")

        let frame = buildBleFrame(commandId: CMD_GET_VOICE_ASSISTANT_STATUS, payload: [0x00])
        print("[validateVoiceAssistantStatus] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateVoiceAssistantStatus] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[validateVoiceAssistantStatus] [characteristic is not writable]")
            return false
        }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_GET_VOICE_ASSISTANT_STATUS
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(5))
        expectedResponseCommandId = nil

        if waitResult == .timedOut {
            print("[validateVoiceAssistantStatus] Timeout waiting for response")
            return false
        }
        if let error = lastError {
            print("[validateVoiceAssistantStatus] Error: \(error.localizedDescription)")
            lastError = nil
            return false
        }
        guard let responseData = lastResponse else {
            print("[validateVoiceAssistantStatus] No response received")
            return false
        }
        lastResponse = nil

        guard let parsedFrame = parseBleFrame(data: responseData), parsedFrame.commandId == CMD_GET_VOICE_ASSISTANT_STATUS else {
            print("[validateVoiceAssistantStatus] Unexpected or unparseable response")
            return false
        }
        guard let firstByte = parsedFrame.payload.first else {
            print("[validateVoiceAssistantStatus] Empty payload")
            return false
        }

        let isLocalOfflineSpeech = (firstByte & 0x01) == 0
        let isAiWakeUp = (firstByte & 0x02) == 0
        print("[validateVoiceAssistantStatus] ✅ isLocalOfflineSpeech=\(isLocalOfflineSpeech) " +
              "isAiWakeUp=\(isAiWakeUp) (raw=0x\(String(format: "%02X", firstByte)))")
        return true
    }

    /// Validates the voice command functionality of the Eyevue glasses
    /// - Returns: true if the voice command was successfully activated, false otherwise
    /// This test sends the VOICE_COMMAND command (0x06) with PARAM_VOICE_COMMAND_ON parameter (0x31)
    /// Note: The Eyevue glasses do not send a response for this command.
    /// The firmware handles the wake word "Hi Luma" for voice activation, but this command
    /// enables/disables manual voice command recognition.
    /// Example: When voice command is activated, the glasses will listen for voice commands
    /// until a VOICE_COMMAND with PARAM_VOICE_COMMAND_OFF (0x30) is sent.
    func validateVoiceCommand() -> Bool {
        print("[validateVoiceCommand] Activating voice command...")
        
        // Build the VOICE_COMMAND frame with PARAM_VOICE_COMMAND_ON to enable voice recognition
        let frame = buildBleFrame(commandId: CMD_VOICE_COMMAND, payload: [PARAM_VOICE_COMMAND_ON])
        print("[validateVoiceCommand] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Verify we have a connected peripheral and the command write characteristic
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateVoiceCommand] Device or characteristic not available")
            return false
        }
        
        // Check if the characteristic supports write operations
        if characteristic.properties.contains(.write) {
            // Send the command to the glasses
            // Note: No response is expected for this command
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
            print("[validateVoiceCommand] ✅ Voice command activated (no response expected)")
            return true
        } else {
            // Characteristic doesn't support write operations
            print("[validateVoiceCommand] [characteristic is not writable]")
            return false
        }
    }
    
    /// Validates the audio recording functionality of the Eyevue glasses
    /// - Returns: true if the 2-second audio recording was successfully started and stopped, false otherwise
    /// This test sends two RECORD_AUDIO commands (0x34):
    /// 1. First with PARAM_RECORD_AUDIO_START (0x01) to begin recording
    /// 2. After 2 seconds, with PARAM_RECORD_AUDIO_END (0x00) to stop recording
    /// Opus packets received via APP_RECEIVE_VOICE_DATA (commandId 0x46) BLE notifications are
    /// collected and muxed into a real, playable Ogg Opus file (see OggOpusMuxer above) saved
    /// with an ISO8601 timestamp in the current directory (e.g., audio_recording_2026-07-17T143000Z.ogg).
    /// Frame display is truncated to 20 bytes by default unless --verbose flag is used.
    func validateAudioRecording() async -> Bool {
        print("[validateAudioRecording] Starting 2-second audio recording...")

        // Build the start recording command frame
        let startFrame = buildBleFrame(commandId: CMD_RECORD_AUDIO, payload: [PARAM_RECORD_AUDIO_START])
        print("[validateAudioRecording] Start frame sent: \(startFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        // Verify we have a connected peripheral and the command write characteristic
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateAudioRecording] Device or characteristic not available")
            return false
        }

        // Check if the characteristic supports write operations
        if characteristic.properties.contains(.write) {
            // Clear the Opus packet list and set the recording flag
            audioPackets = []
            isRecordingAudio = true

            // Create audio file with timestamp in current directory
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let filename = "audio_recording_\(timestamp).ogg"
            let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            audioFileURL = currentDirectory.appendingPathComponent(filename)
            print("[validateAudioRecording] Recording buffer cleared, will be saved to: \(audioFileURL?.path ?? "unknown")")

            // Send the start recording command
            peripheral.writeValue(startFrame, for: characteristic, type: .withResponse)

            // Wait for 3 seconds to record audio (increased from 2s to ensure we capture data)
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds

            // Build the stop recording command frame
            let stopFrame = buildBleFrame(commandId: CMD_RECORD_AUDIO, payload: [PARAM_RECORD_AUDIO_END])
            print("[validateAudioRecording] Stop frame sent: \(stopFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
            // Send the stop recording command
            peripheral.writeValue(stopFrame, for: characteristic, type: .withResponse)

            // Wait a bit more to ensure all audio data is received before finalizing
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

            // Finalize audio recording
            isRecordingAudio = false
            if let fileURL = audioFileURL, !audioPackets.isEmpty {
                let oggData = OggOpusMuxer.buildFile(packets: audioPackets, inputSampleRate: 16000, channelCount: 1)
                do {
                    try oggData.write(to: fileURL)
                    let totalBytes = audioPackets.reduce(0) { $0 + $1.count }
                    let totalSamples = audioPackets.reduce(Int64(0)) { $0 + OggOpusMuxer.packetDurationIn48kSamples($1) }
                    let durationSeconds = Double(totalSamples) / 48000.0
                    print("[validateAudioRecording] ✅ Audio saved to \(fileURL.path) " +
                          "(\(audioPackets.count) Opus packets, \(totalBytes) bytes, ~\(String(format: "%.2f", durationSeconds))s)")
                } catch {
                    print("[validateAudioRecording] ❌ Error saving audio: \(error.localizedDescription)")
                }
            } else if audioPackets.isEmpty {
                print("[validateAudioRecording] ⚠️ No audio data received (no APP_RECEIVE_VOICE_DATA " +
                      "notifications arrived — RECORD_AUDIO alone is not sufficient to start the " +
                      "live BLE mic stream, see Known Hardware Behavior in the README)")
            }

            print("[validateAudioRecording] ✅ 2-second audio recording completed")
            return true
        } else {
            // Characteristic doesn't support write operations
            print("[validateAudioRecording] [characteristic is not writable]")
            return false
        }
    }

    // MARK: - Experimental Probes (mic-audio-stream trigger hunting)
    //
    // RECORD_AUDIO (above) never produces CMD_APP_RECEIVE_VOICE_DATA notifications on real
    // hardware — that command is a local voice-memo capture toggle, unrelated to BLE audio
    // streaming (no pull/transfer mechanism exists for it over BLE at all). The mic audio stream
    // is normally only ever produced by the on-device wake-word/AI assistant pipeline, which a
    // standalone tool has no legitimate way to trigger. The two probes below were long-shot
    // experiments that turned out to work — see each probe's own doc comment below.

    /// Shared by both flavors below: saves whatever is in `audioPackets` as a real Ogg Opus file
    /// (via OggOpusMuxer) and reports the outcome. Called AFTER `isRecordingAudio` has already been
    /// set back to false by the caller's own waiting strategy. Always returns true — these are
    /// exploratory probes with no known-good expected outcome, not correctness tests.
    func finishAudioCapture(label: String) async -> Bool {
        lastTranscribedText = nil
        guard !audioPackets.isEmpty else {
            print("[\(label)] No APP_RECEIVE_VOICE_DATA notifications arrived")
            return true
        }

        let oggData = OggOpusMuxer.buildFile(packets: audioPackets, inputSampleRate: 16000, channelCount: 1)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fileURL = currentDirectory.appendingPathComponent("\(label)_\(timestamp).ogg")
        do {
            try oggData.write(to: fileURL)
            print("[\(label)] 🎉 \(audioPackets.count) audio packets arrived! Saved to \(fileURL.path)")
        } catch {
            print("[\(label)] Received \(audioPackets.count) audio packets, but failed to save: \(error.localizedDescription)")
        }

        // Perform STT using MistralAI whenever an API key is configured. MISTRAL_LANGUAGE is
        // optional — defaults to "fr" (matching MistralAI.Config's own default) so that just
        // setting MISTRAL_API_KEY is enough to enable transcription.
        if let apiKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"], !apiKey.isEmpty {
            let language = ProcessInfo.processInfo.environment["MISTRAL_LANGUAGE"] ?? "fr"
            do {
                let config = MistralAI.Config(
                    apiKey: apiKey,
                    sttLanguage: language,
                    sttModel: "voxtral-mini-latest"
                )
                let mistral = try MistralAI(config: config)
                
                // Transcribe the captured audio
                let transcribedText = try await mistral.transcribe(
                    audioData: oggData,
                    fileName: "\(label)_\(timestamp).ogg",
                    language: language,
                    model: "voxtral-mini-latest"
                )
                
                // Print only the STT result
                print(transcribedText)
                lastTranscribedText = transcribedText
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

        return true
    }

    /// For probeStartVoiceRecognition: APP_START_VOICE_RECOGNITION is fully APP-CONTROLLED — per
    /// its name (and its STOP counterpart existing at all), the stream does not end on its own;
    /// the app is the one responsible for sending APP_STOP_VOICE_RECOGNITION to end it. There is
    /// therefore nothing to "discover" about how it stops on its own (it doesn't) — a short fixed
    /// listening window is all that's needed here before we send the STOP command ourselves.
    private func probeForAudioStreamFixedDuration(label: String, duration: TimeInterval = 5.0) async -> Bool {
        audioPackets = []
        isRecordingAudio = true
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        isRecordingAudio = false
        return await finishAudioCapture(label: label)
    }

    /// For probeDevicePhotoRecognition specifically: UNLIKE probeStartVoiceRecognition, this probe
    /// has no corresponding "stop" command we send — if the resulting stream ends at all, it must
    /// be the glasses' own firmware deciding to end it (fixed duration? silence/VAD detection?).
    /// Listens until ONE of three stop conditions fires (whichever comes first), so a real
    /// end-of-stream beep heard well after this test used to return can be explained:
    ///   1. A genuine commandId 153 end-of-stream notification arrives (`voiceStreamEndMarkerSeen`)
    ///      — the definitive, no-guessing answer, if the firmware sends one.
    ///   2. No new audio packet has arrived for `quietGapSeconds` (default 4s) AFTER at least one
    ///      packet has already arrived — a silence/VAD-based cutoff would show as this firing a
    ///      short, roughly CONSTANT time after the speaker stops, regardless of total speech length.
    ///   3. `maxDuration` (default 30s) safety-net elapses — a fixed-duration cutoff would show as
    ///      this (or condition 1, at a highly consistent elapsed time) firing regardless of when
    ///      the speaker actually stopped talking.
    /// Reports which condition fired and the exact elapsed time, so runs can be compared directly.
    /// - Parameter sendStopCommandOnVADSilence: when true, actively sends APP_STOP_VOICE_RECOGNITION
    ///   (0x56) to the glasses as soon as the VAD-based path (condition 2, using the real Silero-VAD
    ///   backend rather than the packet-timing fallback) detects `quietGapSeconds` of silence. Off by
    ///   default (see `probeDevicePhotoRecognition` above, which has no paired stop command by design)
    ///   — `validatePassiveWakeWordListen` opts into this to test whether telling the glasses to stop
    ///   actually ends a genuinely wake-word-triggered stream.
    func probeForAudioStreamAdaptive(
        label: String, quietGapSeconds: TimeInterval = 4.0, maxDuration: TimeInterval = 30.0,
        sendStopCommandOnVADSilence: Bool = false
    ) async -> Bool {
        audioPackets = []
        wakeWordStartMarkerSeen = false
        voiceStreamEndMarkerSeen = false
        lastAudioPacketAt = nil
        lastSpeechDetectedAt = nil
        pendingVadPcm = []
        vadConsumedPacketIndex = 0
        isRecordingAudio = true
        
        // Initialize VAD if not already done
        if !vadInitialized {
            initializeVAD()
        }
        
        // Reset VAD state for new audio stream
        vad?.reset()
        
        let startTime = Date()
        let pollInterval: TimeInterval = 0.25
        var stopReason = "max duration elapsed with no audio at all"
        var silenceDetected = false
        var stopCommandSent = false

        while true {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            let elapsed = Date().timeIntervalSince(startTime)

            if voiceStreamEndMarkerSeen {
                stopReason = "genuine commandId 153 end-of-stream marker"
                break
            }
            
            // Check for VAD-based silence detection. Decode every newly-arrived packet (not just
            // the last one) into `pendingVadPcm` — a single BLE packet's PCM is far shorter than
            // the model's required window, so several packets' worth must be accumulated before
            // there's enough audio for `isSilence` to produce a meaningful result at all.
            var vadRanThisPoll = false
            if let vad = vad, let decoder = opusDecoder {
                while vadConsumedPacketIndex < audioPackets.count {
                    let packet = audioPackets[vadConsumedPacketIndex]
                    vadConsumedPacketIndex += 1
                    do {
                        let pcm = try decoder.decode(packet: packet)
                        pendingVadPcm.append(contentsOf: pcm)
                    } catch {
                        print("[VAD] Error decoding packet: " + error.localizedDescription)
                    }
                }

                // Consume complete, non-overlapping windows as soon as enough new audio has piled
                // up; leave any short remainder in the buffer for the next poll to top up.
                while pendingVadPcm.count >= vad.requiredSampleCount {
                    let windowChunk = Array(pendingVadPcm.prefix(vad.requiredSampleCount))
                    pendingVadPcm.removeFirst(vad.requiredSampleCount)
                    vadRanThisPoll = true

                    do {
                        // NOTE: intentionally `containsSpeech`, NOT `isSilence`/`process` — those
                        // use a "triggered" hysteresis state machine designed for one-shot
                        // whole-clip analysis that only reports a NEW segment on the very FIRST
                        // window of a silence→speech transition. Calling `isSilence` once per
                        // streaming window here previously meant every window AFTER that first
                        // one of a continuous utterance saw `triggered` already `true` and
                        // reported an (incorrectly) empty segment list — i.e. VAD kept claiming
                        // "silence" for as long as the person kept actually talking.
                        let isSilent = try !vad.containsSpeech(chunk: windowChunk)

                        if isSilent {
                            // If we have speech context and this is silence, check duration since
                            // the VAD last saw actual speech (NOT `lastAudioPacketAt`, which is
                            // bumped on every packet arrival — including silent ones — by the BLE
                            // notification handler, and would therefore never appear "stale").
                            if let lastSpeechEnd = lastSpeechDetectedAt {
                                let silenceDuration = Date().timeIntervalSince(lastSpeechEnd)
                                if silenceDuration >= quietGapSeconds {
                                    stopReason = "VAD detected silence >= " + String(Int(quietGapSeconds)) + "s"
                                    silenceDetected = true
                                    if sendStopCommandOnVADSilence {
                                        stopCommandSent = sendStopVoiceRecognitionCommand(label: label)
                                    }
                                    break
                                }
                            }
                        } else {
                            // This chunk contains speech - update last speech timestamp
                            lastSpeechDetectedAt = Date()
                        }
                    } catch {
                        print("[VAD] Error processing packet: " + error.localizedDescription)
                    }
                }
                if silenceDetected {
                    break
                }
            }
            
            // Fallback: packet-based silence detection (used when no VAD backend is available at
            // all; once a VAD is initialized, silence is always inferred from it above instead).
            if !vadRanThisPoll, vad == nil || opusDecoder == nil,
               let lastPacket = lastAudioPacketAt, Date().timeIntervalSince(lastPacket) >= quietGapSeconds {
                stopReason = "quiet gap >= " + String(Int(quietGapSeconds)) + "s after the last audio packet (silence-based inference)"
                break
            }
            
            if elapsed >= maxDuration {
                stopReason = audioPackets.isEmpty
                    ? "max duration (" + String(Int(maxDuration)) + "s) elapsed with no audio at all"
                    : "max duration (" + String(Int(maxDuration)) + "s) safety cap - stream was still active!"
                break
            }
        }

        let totalElapsed = Date().timeIntervalSince(startTime)
        isRecordingAudio = false

        print("[" + label + "] Wake-word start marker (commandId 151) seen: " + (wakeWordStartMarkerSeen ? "yes" : "no"))
        print("[" + label + "] Listening stopped after " + String(format: "%.1f", totalElapsed) + "s - reason: " + stopReason)
        if silenceDetected {
            print("[" + label + "] Silence detected by VAD (Silero-VAD)")
            if sendStopCommandOnVADSilence {
                print("[" + label + "] Stop-capture command (APP_STOP_VOICE_RECOGNITION) " + (stopCommandSent ? "sent to the glasses" : "could NOT be sent (no peripheral/characteristic)"))
            }
        }
        return await finishAudioCapture(label: label)
    }
    
    /// Sends APP_STOP_VOICE_RECOGNITION (0x56) to the glasses, e.g. once the VAD backend has
    /// confirmed a sustained silence gap during an adaptively-listened audio stream. This is the
    /// same command `probeStartVoiceRecognition` sends defensively after its own fixed-duration
    /// window, reused here to test whether it also ends a genuinely wake-word-triggered stream.
    /// - Returns: true if the command was actually written to the characteristic, false if no
    ///   connected peripheral/writable characteristic was available.
    private func sendStopVoiceRecognitionCommand(label: String) -> Bool {
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic,
              characteristic.properties.contains(.write) else {
            print("[" + label + "] Cannot send stop-capture command: device or characteristic not available")
            return false
        }
        let stopFrame = buildBleFrame(commandId: CMD_APP_STOP_VOICE_RECOGNITION, payload: [0x00])
        print("[" + label + "] VAD-detected silence — sending stop-capture command: " +
              stopFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(stopFrame, for: characteristic, type: .withResponse)
        return true
    }

    /// EXPERIMENTAL: sends APP_START_VOICE_RECOGNITION (0x57). Its name suggests it might start
    /// the same live microphone stream the on-device AI/wake-word pipeline uses — tried here as
    /// a long shot, and confirmed on real hardware to do exactly that.
    ///
    /// This stream is fully APP-CONTROLLED: it does not end on its own (that's what the paired
    /// APP_STOP_VOICE_RECOGNITION below is for), so a short fixed listening window is used rather
    /// than the adaptive end-of-stream detection in probeDevicePhotoRecognition below — there is no
    /// "how does it stop by itself" question to answer here.
    func probeStartVoiceRecognition() async -> Bool {
        print("[probeStartVoiceRecognition] Sending APP_START_VOICE_RECOGNITION (untested by the real app)...")
        let frame = buildBleFrame(commandId: CMD_APP_START_VOICE_RECOGNITION, payload: [0x00])
        print("[probeStartVoiceRecognition] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[probeStartVoiceRecognition] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[probeStartVoiceRecognition] [characteristic is not writable]")
            return false
        }

        peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        let result = await probeForAudioStreamFixedDuration(label: "probeStartVoiceRecognition")

        // Try to leave the device in a clean state regardless of the outcome above.
        let stopFrame = buildBleFrame(commandId: CMD_APP_STOP_VOICE_RECOGNITION, payload: [0x00])
        print("[probeStartVoiceRecognition] Stop frame sent: \(stopFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        peripheral.writeValue(stopFrame, for: characteristic, type: .withResponse)

        return result
    }

    /// CONFIRMED WORKING (real hardware): sends DEVICE_PHOTO_RECOGNITION (0x0A). This commandId
    /// is normally a NOTIFICATION the glasses send TO the app, not a command the app itself would
    /// normally send — so writing it here was a genuine long-shot. It is NOT ignored: on real
    /// hardware, sending it produced a genuine, CRC-valid
    /// commandId-151 notification FROM the glasses (0xAC 55 00 03 97 01 98) — the same code the
    /// real wake-word event uses — immediately followed by a live APP_RECEIVE_VOICE_DATA (0x46)
    /// stream, with no APP_START_VOICE_RECOGNITION involved at all. This is arguably a closer
    /// simulation of a genuine "Hi Luma" utterance than probeStartVoiceRecognition above, since it
    /// reproduces both the wake-word notification AND the resulting audio stream as a package.
    ///
    /// UNLIKE probeStartVoiceRecognition, there is no paired "stop" command we send for this one —
    /// if the resulting stream ends, it's the glasses deciding to end it on their own (a real,
    /// differently-pitched "end" beep has been heard well after this test used to return under the
    /// old fixed 3s window). So this uses the adaptive end-of-stream detection instead of a fixed
    /// duration, specifically to answer whether that's a fixed timeout or a silence/VAD cutoff.
    func probeDevicePhotoRecognition() async -> Bool {
        print("[probeDevicePhotoRecognition] Sending DEVICE_PHOTO_RECOGNITION (confirmed to trigger a wake-word-style notification + audio stream)...")
        let frame = buildBleFrame(commandId: CMD_DEVICE_PHOTO_RECOGNITION, payload: [0x00])
        print("[probeDevicePhotoRecognition] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[probeDevicePhotoRecognition] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[probeDevicePhotoRecognition] [characteristic is not writable]")
            return false
        }

        peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        return await probeForAudioStreamAdaptive(label: "probeDevicePhotoRecognition")
    }

    /// PASSIVE TEST — sends NOTHING over BLE to START the stream. Testing has shown that nothing
    /// in the normal conversational flow ever tells the glasses to stop streaming on its own — so
    /// any self-termination would have to come from the glasses' own firmware reacting to a REAL,
    /// physically-detected wake word, not from anything this tool sends. `probeDevicePhotoRecognition`
    /// synthesizes commandId 10 from the app side, which may bypass whatever internal state
    /// machine a genuine on-device wake-word detection goes through (including its own
    /// silence/VAD-driven end-of-stream logic, if any). This test removes that confound entirely:
    /// it arms the same listening logic but never writes anything to START the stream, waiting
    /// for an actual spoken "Hi Luma" to do all the triggering.
    ///
    /// UNLIKE probeDevicePhotoRecognition, this test DOES actively send a stop-capture command
    /// (APP_STOP_VOICE_RECOGNITION, 0x56) to the glasses as soon as the Silero-VAD backend detects
    /// 3 seconds of silence following real speech — testing whether the glasses honor an explicit
    /// stop request for a stream that was itself started by a genuine, physically-spoken wake word
    /// rather than by one of this tool's own commands.
    func validatePassiveWakeWordListen() async -> Bool {
        print("""
        [passiveWakeWordListen] ℹ️ This test sends NOTHING over BLE to start listening. It only
        arms the microphone-audio capture and watches passively for a genuine, physically-spoken
        wake word. Once 3 seconds of silence are detected by the Silero-VAD backend, it WILL
        actively send a stop-capture command (APP_STOP_VOICE_RECOGNITION) to the glasses.

        WHAT TO DO BEFORE YOU PRESS ENTER:
          1. Get ready to say "Hi Luma" to the glasses OUT LOUD.
          2. Listening starts the INSTANT you press enter below — so only press enter once you are
             ready to speak within the next second or two.
          3. After the wake-word beep, speak a short sentence, then go quiet and just wait — don't
             say anything else. This is what lets the test tell apart a fixed-duration cutoff from
             a silence-based one (it stops on whichever of: a real commandId-153 end marker, 3s of
             VAD-detected silence after your last word (which also sends the stop command), or a
             30s safety cap — comes first).

        """)
    
        print("[passiveWakeWordListen] Press enter when ready to start listening...")
        _ = readLine()

        return await probeForAudioStreamAdaptive(
            label: "passiveWakeWordListen", quietGapSeconds: 3.0, sendStopCommandOnVADSilence: true)
    }

    /// Validates the photo capture functionality of the Eyevue glasses end-to-end.
    /// - Returns: true if the photo was successfully captured, fully transferred, and saved to disk
    /// This test sends TAKE_PHOTO (0x22) with the high-quality parameter, waits for the short
    /// acknowledgement on UUID_CMD_NOTIFY (informational only), and then — unlike a naive
    /// implementation that would stop right there — actually waits for and reassembles the
    /// complete JPEG transferred separately on UUID_PHOTO_NOTIFY via PHOTO_START (0x97) /
    /// PHOTO_TRANS (0x98) / PHOTO_END (0x99).
    ///
    /// This matters because the glasses play their physical shutter/"photo taken" sound as soon
    /// as the capture itself completes on-device, well before the (potentially multi-hundred-ms)
    /// BLE transfer of the resulting JPEG is done. A version of this test that only waited for
    /// the short ack would report success — and this whole validation run would move on to
    /// printing results and disconnecting — while the actual photo transfer was still in flight,
    /// silently truncating or dropping it entirely.
    func validateTakePhoto() -> Bool {
        print("[validateTakePhoto] Taking high quality photo...")

        // Build the TAKE_PHOTO command frame with high quality parameter
        let frame = buildBleFrame(commandId: CMD_TAKE_PHOTO, payload: [PARAM_TAKE_PHOTO_HIGH_QUALITY])
        print("[validateTakePhoto] Frame sent: \(frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))")

        // Verify we have a connected peripheral and the command write characteristic
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic else {
            print("[validateTakePhoto] Device or characteristic not available")
            return false
        }
        guard characteristic.properties.contains(.write) else {
            print("[validateTakePhoto] [characteristic is not writable]")
            return false
        }

        // Arm photo capture state BEFORE sending the command: PHOTO_START can arrive very
        // quickly after the shutter click on real hardware, so there must be no window where a
        // notification could arrive before we're ready to treat it as photo data.
        photoBuffer = Data()
        expectedPhotoSize = nil
        photoTransferComplete = false
        isCapturingPhoto = true

        // Set expected response command ID to filter the short command-channel acknowledgement
        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_TAKE_PHOTO
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let ackTimeout = DispatchTime.now() + .seconds(5)
        let ackWaitResult = responseSemaphore.wait(timeout: ackTimeout)
        expectedResponseCommandId = nil

        if ackWaitResult == .timedOut {
            print("[validateTakePhoto] Timeout waiting for capture acknowledgement")
            isCapturingPhoto = false
            return false
        }
        if let error = lastError {
            print("[validateTakePhoto] Error: \(error.localizedDescription)")
            lastError = nil
            isCapturingPhoto = false
            return false
        }
        if let responseData = lastResponse {
            lastResponse = nil
            if let parsedFrame = parseBleFrame(data: responseData), parsedFrame.commandId == CMD_TAKE_PHOTO {
                print("[validateTakePhoto] Capture acknowledged, waiting for photo transfer " +
                      "(PHOTO_START/PHOTO_TRANS/PHOTO_END on UUID_PHOTO_NOTIFY)...")
            } else {
                print("[validateTakePhoto] Unexpected acknowledgement, waiting for photo transfer anyway...")
            }
        } else {
            print("[validateTakePhoto] No acknowledgement received, waiting for photo transfer anyway...")
        }

        // Now wait for the ACTUAL photo transfer to complete. Real captures (12 KB JPEGs) take
        // well under a second once started, but a generous timeout leaves headroom for larger
        // high-resolution shots.
        let transferTimeout = DispatchTime.now() + .seconds(15)
        let transferWaitResult = photoSemaphore.wait(timeout: transferTimeout)
        isCapturingPhoto = false

        guard transferWaitResult != .timedOut, photoTransferComplete else {
            print("[validateTakePhoto] ❌ Timeout waiting for full photo transfer " +
                  "(got \(photoBuffer.count) of \(expectedPhotoSize.map(String.init) ?? "unknown") bytes)")
            return false
        }

        if let expected = expectedPhotoSize, expected != photoBuffer.count {
            print("[validateTakePhoto] ⚠️ Received \(photoBuffer.count) bytes, " +
                  "but PHOTO_START announced \(expected) bytes")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "photo_\(timestamp).jpg"
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fileURL = currentDirectory.appendingPathComponent(filename)
        do {
            try photoBuffer.write(to: fileURL)
            print("[validateTakePhoto] ✅ Photo saved to \(fileURL.path) (\(photoBuffer.count) bytes)")
            return true
        } catch {
            print("[validateTakePhoto] ❌ Error saving photo: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Running validation tests
    
    /// Executes all validation tests sequentially and reports the results
    /// This function is called after BLE characteristics are discovered and notifications are enabled.
    /// It runs the following tests in order:
    /// 1. Battery level validation
    /// 2. Storage capacity validation
    /// 3. Device firmware info (BT/ISP/device versions)
    /// 4. Hardware capability bitmask (incl. AI wake-word support)
    /// 5. Voice assistant / wake-word status
    /// 6. Voice command activation
    /// 7. Audio recording (2 seconds) — expected to report no audio: RECORD_AUDIO is a local
    ///    voice-memo toggle, not a BLE streaming trigger
    /// 8. Probe: APP_START_VOICE_RECOGNITION — confirmed mic-stream trigger, app-controlled (needs
    ///    an explicit STOP; fixed short listening window)
    /// 9. Probe: DEVICE_PHOTO_RECOGNITION — confirmed to trigger a wake-word-style notification +
    ///    audio stream; adaptive listening (153 marker / silence gap / max duration)
    /// 10. Passive: listens for a REAL spoken "Hi Luma" (sends nothing over BLE) — isolates
    ///     whether self-termination is a glasses-firmware behavior tied to the genuine wake-word
    ///     path, as opposed to something bypassed by synthesizing commandId 10 in test 9
    /// 11. Photo capture — waits for and saves the full JPEG, not just the initial acknowledgement
    /// Each test is executed with a delay between them to ensure proper sequencing.
    func runValidationTests() async {
        // Ensure validation tests run only once
        guard !validationTestsCompleted else {
            print("[runValidationTests] Validation tests already completed, skipping...")
            return
        }
        validationTestsCompleted = true
        
        // Verify we have a connected peripheral
        guard let peripheral = connectingPeripheral else {
            print("[runValidationTests] No device connected")
            validationTestsCompleted = false  // Reset flag to allow retry
            return
        }
        
        print("\n=== Starting validation tests ===\n")

        // Delay execution to ensure BLE connection is stable. This function is only ever invoked
        // (see didDiscoverCharacteristicsFor) on a background queue distinct from `bleQueue` — the
        // one CoreBluetooth uses to deliver `didUpdateValueFor` — so blocking this thread with
        // `Task.sleep`/`responseSemaphore.wait` below does NOT starve notification delivery the
        // way it did when this whole block ran on the main queue via `DispatchQueue.main.asyncAfter`.
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        do {
            // Verify that required BLE characteristics are available
            if self.cmdWriteCharacteristic == nil || self.cmdNotifyCharacteristic == nil {
                print("[runValidationTests] Required BLE characteristics are not available")
                return
            }

            // Enable notifications for command responses
            if let cmdNotifyChar = self.cmdNotifyCharacteristic {
                peripheral.setNotifyValue(true, for: cmdNotifyChar)
            }

            // Enable notifications for photo data (if available)
            // Photo notifications may contain status codes for photo capture progress
            if let photoNotifyChar = self.photoNotifyCharacteristic {
                peripheral.setNotifyValue(true, for: photoNotifyChar)
            }

            // Determine which tests to run
            let testsToRun: [(swiftName: String, displayName: String, description: String)] = {
                if let specificTestNames = self.specificTestNames, !specificTestNames.isEmpty {
                    // Filter tests based on the provided Swift names
                    var selectedTests: [(swiftName: String, displayName: String, description: String)] = []
                    for testName in specificTestNames {
                        if let test = BleProbe.allTests.first(where: { $0.swiftName == testName }) {
                            selectedTests.append(test)
                        } else {
                            print("[runValidationTests] Warning: Test '\(testName)' not found, skipping...")
                        }
                    }
                    return selectedTests
                } else {
                    // Run all tests
                    return BleProbe.allTests
                }
            }()

            // Execute each test and store results
            var results: [String: Bool] = [:]
            for test in testsToRun {
                print("\n--- Test: \(test.displayName) ---")
                
                // Add a pause before audio tests
                let audioTestNames = ["Audio recording (2s)", "Audio: start voice recording", "Audio: device photo recognition",
                                      "Cancel: voice recognition during stream", "Cancel: AI voice during stream"]
                if audioTestNames.contains(test.displayName) {
                    print("Press enter to run audio test \(test.displayName)")
                    _ = readLine()
                }
                
                // Call the appropriate test function based on the swiftName
                let result: Bool
                switch test.swiftName {
                case "validateBattery": result = self.validateBattery()
                case "validateStorageCapacity": result = self.validateStorageCapacity()
                case "validateDeviceInfo": result = self.validateDeviceInfo()
                case "validateSupportFunction": result = self.validateSupportFunction()
                case "validateTakePhoto": result = self.validateTakePhoto()
                case "validateVoiceCommand": result = self.validateVoiceCommand()
                case "validateVoiceAssistantStatus": result = self.validateVoiceAssistantStatus()
                case "validateAudioRecording": result = await self.validateAudioRecording()
                case "probeStartVoiceRecognition": result = await self.probeStartVoiceRecognition()
                case "probeDevicePhotoRecognition": result = await self.probeDevicePhotoRecognition()
                case "validatePassiveWakeWordListen": result = await self.validatePassiveWakeWordListen()
                case "validateSetVoiceAssistantStatus": result = self.validateSetVoiceAssistantStatus()
                case "probeCancelVoiceRecognitionDuringStream": result = await self.probeCancelVoiceRecognitionDuringStream()
                case "probeCancelAiVoiceDuringStream": result = await self.probeCancelAiVoiceDuringStream()
                case "probeOpenWifiMediaImport": result = self.probeOpenWifiMediaImport()
                case "validateActionSyncPassiveListen": result = await self.validateActionSyncPassiveListen()
                case "validateTakePhotoSizeConsistency": result = self.validateTakePhotoSizeConsistency()
                case "validateHiLumaDemo": result = await self.validateHiLumaDemo()
                default: result = false
                }
                
                results[test.displayName] = result
                print("Result: \(result ? "✅ SUCCESS" : "❌ FAILED")")

                // Add a small delay between tests to avoid BLE notification conflicts
                // This is especially important for audio recording which takes 3+ seconds
                if test.displayName != "Audio: device photo recognition" {  // No delay after last test
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                }
            }

            // Display final test results summary (following the same order as the tests)
            print("\n=== Test Results ===")
            for test in testsToRun {
                let result = results[test.displayName] ?? false
                print("\(result ? "✅" : "❌") \(test.displayName): \(result ? "SUCCESS" : "FAILED")")
            }
            
            // Disconnect from the device and exit after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("\n[runValidationTests] Disconnecting...")
                self.central.cancelPeripheralConnection(peripheral)
                exit(0)
            }
        }
    }

    // MARK: - CoreBluetooth Delegate Methods
    
    /// Called when the Bluetooth state changes
    /// Handles different states of the Bluetooth central manager and initiates scanning when ready
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Bluetooth is available and authorized, start scanning for devices
            print("[state] poweredOn — Bluetooth is available and authorized. Scanning for \(Int(scanDuration))s...")
            central.scanForPeripherals(withServices: nil, options: nil)
            // Stop scanning after the specified duration
            DispatchQueue.main.asyncAfter(deadline: .now() + scanDuration) { [weak self] in
                self?.central.stopScan()
                print("[scan] stopped after \(Int(scanDuration))s.")
                // Check if we found a matching device
                if self?.connectingPeripheral == nil {
                    print("[result] No device matching \"\(self?.targetName ?? "E09")\" was found. " +
                          "See the [found] lines above for whatever WAS discovered nearby.")
                    exit(0)
                }
            }
        case .poweredOff:
            // Bluetooth is turned off, cannot proceed
            print("[state] poweredOff — turn on Bluetooth in System Settings and run again.")
            exit(1)
        case .unauthorized:
            // Bluetooth permission not granted, cannot proceed
            print("[state] unauthorized — grant Bluetooth permission in System Settings > " +
                  "Privacy & Security > Bluetooth for the app/terminal running this tool, then run again.")
            exit(1)
        case .unsupported:
            // This Mac doesn't support BLE, cannot proceed
            print("[state] unsupported — this Mac's hardware/OS does not support Bluetooth Low Energy.")
            exit(1)
        case .resetting:
            // Bluetooth is resetting, wait for next state update
            print("[state] resetting...")
        case .unknown:
            // Bluetooth state is unknown (still initializing)
            print("[state] unknown (still initializing)...")
        @unknown default:
            // Handle any future unknown states
            print("[state] unrecognized CBManagerState value.")
        }
    }

    /// Called when a BLE peripheral is discovered during scanning
    /// Checks if the device matches our target name substring and connects if it does
    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Extract the peripheral name from various sources
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "(no name)"

        // Log all discovered devices (to help with debugging)
        if !seenIdentifiers.contains(peripheral.identifier) {
            seenIdentifiers.insert(peripheral.identifier)
            // Extract advertised service UUIDs for logging
            let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map { $0.uuidString } ?? []
            // Extract manufacturer data for logging
            let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?
                .map { String(format: "%02x", $0) }.joined() ?? "(none)"
            print("[found] \(peripheral.identifier) name=\"\(name)\" rssi=\(RSSI) " +
                  "advertisedServices=\(serviceUUIDs) manufacturerData=\(manufacturerData)")
        }

        // Connect to the first device that matches our target name substring
        if name.contains(targetName), connectingPeripheral == nil {
            print("[match] \"\(name)\" matches \"\(targetName)\" — connecting directly " +
                  "(no service filter) to inspect its real GATT services...")
            connectingPeripheral = peripheral
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    /// Called when a connection to a peripheral is successfully established
    /// Starts service discovery to find the Eyevue service and its characteristics
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[connected] to \(peripheral.identifier). Discovering services...")
        // Set self as the peripheral delegate to receive characteristic discovery events
        peripheral.delegate = self
        // Discover all services on the peripheral (nil = discover all services)
        peripheral.discoverServices(nil)
    }

    /// Called when a connection to a peripheral fails
    /// Logs the error and continues scanning for other devices
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[connect-failed] \(error?.localizedDescription ?? "unknown error")")
        exit(1)
    }

    /// Called when service discovery completes for a peripheral
    /// Logs all discovered services and starts characteristic discovery for each
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Handle service discovery errors
        if let error = error {
            print("[service-discovery-failed] \(error.localizedDescription)")
            exit(1)
        }
        
        // Check if any services were found
        guard let services = peripheral.services, !services.isEmpty else {
            print("[services] none found.")
            self.central.cancelPeripheralConnection(peripheral)
            exit(0)
        }
        
        // Log all discovered services
        print("[services] found \(services.count) service(s):")
        pendingServiceCount = services.count
        for service in services {
            print("  - \(service.uuid.uuidString)")
            // Discover all characteristics for each service
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// Called when characteristic discovery completes for a service
    /// Logs all discovered characteristics and stores the ones we need for the Eyevue protocol
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Handle characteristic discovery errors
        if let error = error {
            print("      (characteristic discovery for \(service.uuid.uuidString) failed: \(error.localizedDescription))")
            return
        }
        
        // Log all discovered characteristics for this service
        for characteristic in service.characteristics ?? [] {
            print("      \(service.uuid.uuidString) -> \(characteristic.uuid.uuidString) " +
                  "properties=\(characteristic.properties)")
            
            // Store references to the Eyevue protocol characteristics we need
            // These will be used for sending commands and receiving responses
            if characteristic.uuid == UUID_CMD_WRITE {
                cmdWriteCharacteristic = characteristic
            } else if characteristic.uuid == UUID_CMD_NOTIFY {
                cmdNotifyCharacteristic = characteristic
            } else if characteristic.uuid == UUID_PHOTO_NOTIFY {
                photoNotifyCharacteristic = characteristic
            }
        }
        
        // didDiscoverCharacteristicsFor fires once per service; only act once every service has
        // reported back, instead of guessing with a fixed delay (which used to also trigger
        // runValidationTests() redundantly, once per service — visible in logs as repeated
        // "Validation tests already completed, skipping..." lines).
        pendingServiceCount -= 1
        guard pendingServiceCount <= 0 else { return }

        // Verify we have the required characteristics for validation tests
        if self.cmdWriteCharacteristic != nil && self.cmdNotifyCharacteristic != nil {
            print("\n[services] Required characteristics found. Starting validation tests...")
            // Run the (blocking) validation tests on a background queue, never on `bleQueue` —
            // that queue is where CoreBluetooth delivers `didUpdateValueFor`, and the tests below
            // block synchronously waiting on that exact callback via `responseSemaphore.wait(...)`.
            Task {
                await self.runValidationTests()
            }
        } else {
            // Cannot run validation tests without required characteristics
            print("\n[services] Required characteristics not found. Disconnecting...")
            self.central.cancelPeripheralConnection(peripheral)
            exit(0)
        }
    }
    
    // MARK: - Response Handling
    
    /// Called when a characteristic value is updated (notification received)
    /// Handles incoming BLE responses from the Eyevue glasses and signals the semaphore
    /// to unblock waiting validation functions.
    /// For audio data received during recording, it reassembles frames and saves to a file with timestamp.
    /// Frame display is truncated to 20 bytes by default unless --verbose flag is used.
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Handle any errors that occurred during notification
        if let error = error {
            print("[notification-error] \(error.localizedDescription)")
            lastError = error
            // Signal the semaphore to unblock waiting code
            responseSemaphore.signal()
            return
        }
        
        // Process the received value if present
        if let value = characteristic.value {
            // ACTION_SYNC (0x45) passive listener for validateActionSyncPassiveListen —
            // purely observational, does not interfere with any other expectedResponseCommandId
            // wait since it only activates while isCapturingActionSync is explicitly armed.
            if characteristic.uuid == UUID_CMD_NOTIFY, isCapturingActionSync,
               let syncFrame = parseBleFrame(data: value), syncFrame.commandId == CMD_ACTION_SYNC {
                actionSyncFramesSeen.append(syncFrame.payload)
                print("[action-sync] " + decodeActionSyncFlags(syncFrame.payload))
                return
            }

            // Photo file-transfer frames (PHOTO_START/PHOTO_TRANS/PHOTO_END) on UUID_PHOTO_NOTIFY
            // use a different framing (SOF 0x52 0x58 + footer, see parseFileFrame) than the regular
            // command protocol — `parseBleFrame` would simply fail to parse them (wrong SOF). Only
            // interpret them this way while a photo capture is actually in progress, so plain
            // diagnostic-mode scans still just print raw notification bytes as before.
            if characteristic.uuid == UUID_PHOTO_NOTIFY, isCapturingPhoto,
               let (fileCommandId, filePayload) = parseFileFrame(data: value) {
                switch fileCommandId {
                case CMD_PHOTO_START:
                    expectedPhotoSize = nil
                    if filePayload.count >= 4 {
                        // Bytes 2-3 of the PHOTO_START payload carry the total JPEG size,
                        // big-endian (confirmed against real hardware captures).
                        expectedPhotoSize = (Int(filePayload[2]) << 8) | Int(filePayload[3])
                    }
                    // Pre-size the buffer to the announced length (zero-filled) so PHOTO_TRANS
                    // chunks below can write directly at their announced offset, rather than
                    // relying on arrival order.
                    photoBuffer = Data(count: expectedPhotoSize ?? 0)
                    photoHighWaterMark = 0
                    print("[photo] PHOTO_START — expecting \(expectedPhotoSize.map(String.init) ?? "an unknown number of") bytes")
                case CMD_PHOTO_TRANS:
                    // The first 4 bytes are the cumulative byte offset already transferred before
                    // this chunk, big-endian. Real hardware has been observed occasionally
                    // re-delivering/overlapping a chunk (a straight sequential `append` of every
                    // chunk in arrival order corrupted the reassembled JPEG by duplicating data)
                    // — writing each chunk at its OWN declared offset instead makes reassembly
                    // correct regardless of arrival order and idempotent against a duplicate.
                    guard filePayload.count > 4 else { break }
                    let offset = (Int(filePayload[0]) << 24) | (Int(filePayload[1]) << 16)
                        | (Int(filePayload[2]) << 8) | Int(filePayload[3])
                    let chunkData = Array(filePayload[4...])
                    let endOffset = offset + chunkData.count

                    if offset < photoHighWaterMark {
                        print("[photo] ⚠️ PHOTO_TRANS chunk at offset \(offset) overlaps data already " +
                              "written up to \(photoHighWaterMark) — writing it anyway (likely a duplicate/retransmit)")
                    }

                    if photoBuffer.count < endOffset {
                        photoBuffer.append(contentsOf: repeatElement(0, count: endOffset - photoBuffer.count))
                    }
                    photoBuffer.replaceSubrange(offset..<endOffset, with: chunkData)
                    photoHighWaterMark = max(photoHighWaterMark, endOffset)
                case CMD_PHOTO_END:
                    photoTransferComplete = true
                    if let expected = expectedPhotoSize, photoHighWaterMark < expected {
                        print("[photo] ⚠️ PHOTO_END arrived after only \(photoHighWaterMark) of \(expected) " +
                              "bytes were actually written — at least one chunk was likely lost")
                    }
                    print("[photo] PHOTO_END — received \(photoBuffer.count) bytes total")
                    photoSemaphore.signal()
                default:
                    break
                }
                return
            }

            // Real microphone audio only ever arrives as APP_RECEIVE_VOICE_DATA (commandId 0x46)
            // on UUID_CMD_NOTIFY — it uses the regular command-frame protocol (SOF 0xAC 0x55),
            // not the file-transfer one on AA15 (that's photos only, see the
            // PHOTO_START/TRANS/END branch above). Intercepted unconditionally (NOT gated by
            // isRecordingAudio) — real hardware keeps streaming audio well past whatever stop
            // condition our own probes choose (no genuine end-of-stream marker and no
            // reliably-detected silence gap), so trailing 0x46 packets keep arriving after
            // a test has already moved on. Previously these fell through to the generic
            // notification branch below once isRecordingAudio went false, which printed an
            // unlabeled dot AND touched responseSemaphore/lastResponse — visually interleaving
            // with whichever test happened to run next and making it look like the PREVIOUS test
            // never finished. Swallowing them here (silently, when not actively recording) fixes
            // that without affecting the real recording path.
            if characteristic.uuid == UUID_CMD_NOTIFY,
               let parsedFrame = parseBleFrame(data: value), parsedFrame.commandId == CMD_APP_RECEIVE_VOICE_DATA {
                if isRecordingAudio {
                    // Keep this as its own packet (not concatenated into one blob): Ogg Opus
                    // muxing needs each Opus packet's boundaries intact to read its TOC byte
                    // correctly. Anything else arriving on AA14 while recording (e.g. an
                    // unrelated ACTION_SYNC push) is NOT audio data and must not be mixed into
                    // the buffer — doing so previously corrupted the saved file (it was neither
                    // valid Opus nor anything else a decoder could make sense of).
                    audioPackets.append(parsedFrame.payload)
                    lastAudioPacketAt = Date()

                    // Display frame info based on output mode
                    displayNotification(value, on: characteristic, prefix: "[audio]")

                    // DO NOT signal the semaphore for audio data to avoid interfering with other tests
                    // Audio data is accumulated in the buffer and saved at the end of the recording
                }
                // else: trailing/orphaned packet from a stream our own test already stopped
                // listening to — silently dropped, see comment above.
                return
            } else {
                // Regular notification (not audio data)

                // While a voice stream is being captured, watch for the genuine start (151) and
                // end (153) markers — the same triple-alias commandIds as PHOTO_START/PHOTO_END,
                // but on the command channel they mean "wake word fired" / "AI voice stream ended".
                // This runs regardless of expectedResponseCommandId so it's never
                // missed just because some other wait is in progress, and lets
                // probeForAudioStreamAdaptive/validatePassiveWakeWordListen stop deterministically
                // instead of only guessing from a quiet gap.
                if characteristic.uuid == UUID_CMD_NOTIFY, isRecordingAudio,
                   let markerFrame = parseBleFrame(data: value) {
                    if markerFrame.commandId == CMD_WAKE_WORD_START {
                        wakeWordStartMarkerSeen = true
                        print("[voice-stream] 🔔 Genuine commandId 151 wake-word notification from the glasses")
                    } else if markerFrame.commandId == CMD_VOICE_STREAM_END {
                        voiceStreamEndMarkerSeen = true
                        print("[voice-stream] 🔚 Genuine commandId 153 end-of-stream notification from the glasses")
                    }
                }

                // Check if this notification matches the expected response command ID
                // If expectedResponseCommandId is set, only process notifications that match
                if let expectedCommandId = expectedResponseCommandId {
                    // Parse the frame to check if it matches the expected command
                    if let parsedFrame = parseBleFrame(data: value) {
                        let (commandId, _, _) = parsedFrame
                        if commandId == expectedCommandId {
                            // This is the response we're waiting for
                            lastResponse = value
                            expectedResponseCommandId = nil  // Clear the expected command
                            responseSemaphore.signal()
                            
                            // Display frame info based on output mode
                            displayNotification(value, on: characteristic)
                        } else {
                            // Not the expected response, just display it
                            displayNotification(value, on: characteristic)
                        }
                    } else {
                        // Failed to parse, just display
                        displayNotification(value, on: characteristic)
                    }
                } else {
                    // No expected command ID, store all responses
                    lastResponse = value
                    responseSemaphore.signal()
                    
                    // Display frame info with truncation
                    displayNotification(value, on: characteristic)
                }
            }
        }
    }
}
