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

// MARK: - ACTION_SYNC flag decoding

/// Decodes an ACTION_SYNC (commandId 0x45/69) payload: 9 booleans at bytes 0-8 (each active
/// when == 1), plus an optional 10th boolean (isImport) at byte 9 if present. Returns a
/// human-readable list of the flags that are currently active.
func decodeActionSyncFlags(_ payload: [UInt8]) -> String {
    guard payload.count >= 9 else { return "payload too short (\(payload.count) bytes)" }
    let names = ["isTakePhoto", "isTakeAudio", "isTakeVideo", "isVolumeUp", "isVolumeDown",
                 "isNod", "isShakeHand", "isPlayMusic", "isWear"]
    var active: [String] = []
    for i in 0..<9 {
        if payload[i] == 1 { active.append(names[i]) }
    }
    if payload.count >= 10, payload[9] == 1 { active.append("isImport") }
    return active.isEmpty ? "(no flags set)" : active.joined(separator: ", ")
}

// MARK: - SET_VOICE_ASSISTANT_STATUS round-trip

extension BleProbe {

    /// Validates SET_VOICE_ASSISTANT_STATUS (0x72/114) — the write counterpart of
    /// GET_VOICE_ASSISTANT_STATUS (0x71, `validateVoiceAssistantStatus`). Reads the current
    /// status byte, flips the isAiWakeUp bit (bit 1, inverted encoding — see
    /// `validateVoiceAssistantStatus` for the full bit layout), writes it back, re-reads to
    /// confirm the change stuck, then restores the ORIGINAL byte and confirms the restoration
    /// too — this is a persistent device setting, not a session flag, so the test must leave
    /// the device exactly as it found it.
    /// - Returns: true only if both the toggle AND the restore were confirmed by a
    ///   subsequent GET_VOICE_ASSISTANT_STATUS read-back.
    func validateSetVoiceAssistantStatus() -> Bool {
        print("[validateSetVoiceAssistantStatus] Reading current voice assistant status byte...")

        guard let originalByte = readVoiceAssistantStatusByte() else {
            print("[validateSetVoiceAssistantStatus] Could not read initial status — aborting")
            return false
        }
        print("[validateSetVoiceAssistantStatus] Initial raw byte: 0x\(String(format: "%02X", originalByte))")

        // The status byte uses inverted encoding for isAiWakeUp (bit 1): the bit is SET (1)
        // when the feature is OFF, and CLEAR (0) when ON — so "toggle" means flip the bit
        // value itself, which inverts the semantic state.
        let toggledByte = originalByte ^ 0x02
        print("[validateSetVoiceAssistantStatus] Toggled byte (isAiWakeUp bit flipped): 0x\(String(format: "%02X", toggledByte))")

        let writeSent = writeVoiceAssistantStatusByte(toggledByte)
        guard writeSent else {
            print("[validateSetVoiceAssistantStatus] Write command could not be sent — aborting")
            return false
        }

        // Brief settle delay before re-reading — the device needs a moment to persist the
        // change to its non-volatile setting.
        Thread.sleep(forTimeInterval: 0.5)

        guard let readBackByte = readVoiceAssistantStatusByte() else {
            print("[validateSetVoiceAssistantStatus] Could not read back status after toggling — " +
                  "device may be left in a modified state, manual check recommended")
            return false
        }

        let toggleConfirmed = readBackByte == toggledByte
        print("[validateSetVoiceAssistantStatus] After toggle: raw byte=0x\(String(format: "%02X", readBackByte)) " +
              "(\(toggleConfirmed ? "✅ matches expected toggle" : "❌ does not match expected toggle"))")

        // Always attempt to restore the original setting, even if the toggle didn't confirm.
        let restoreSent = writeVoiceAssistantStatusByte(originalByte)
        let restoredByte = restoreSent ? readVoiceAssistantStatusByte() : nil
        let restoreConfirmed = restoredByte == originalByte
        print("[validateSetVoiceAssistantStatus] Restore attempt: raw byte=" +
              (restoredByte.map { "0x" + String(format: "%02X", $0) } ?? "unknown") +
              " (\(restoreConfirmed ? "✅ restored" : "❌ NOT confirmed restored — check device manually"))")

        return toggleConfirmed && restoreConfirmed
    }

    /// Reads the current voice-assistant status byte via GET_VOICE_ASSISTANT_STATUS (0x71).
    /// Shared by validateSetVoiceAssistantStatus for its pre-toggle/post-toggle/post-restore reads.
    func readVoiceAssistantStatusByte() -> UInt8? {
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic,
              characteristic.properties.contains(.write) else { return nil }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_GET_VOICE_ASSISTANT_STATUS
        let frame = buildBleFrame(commandId: CMD_GET_VOICE_ASSISTANT_STATUS, payload: [0x00])
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(5))
        expectedResponseCommandId = nil
        guard waitResult != .timedOut, let responseData = lastResponse else { return nil }
        lastResponse = nil
        guard let parsedFrame = parseBleFrame(data: responseData),
              parsedFrame.commandId == CMD_GET_VOICE_ASSISTANT_STATUS,
              let firstByte = parsedFrame.payload.first else { return nil }
        return firstByte
    }

    /// Writes a voice-assistant status byte via SET_VOICE_ASSISTANT_STATUS (0x72). This
    /// command's ack behavior has never been confirmed on real hardware — it may or may not
    /// echo back commandId 0x72. A short wait is attempted but its timeout is NOT treated as
    /// failure (several CMD-type write-only commands in this protocol, e.g. VOICE_COMMAND,
    /// never ack).
    func writeVoiceAssistantStatusByte(_ value: UInt8) -> Bool {
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic,
              characteristic.properties.contains(.write) else { return false }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_SET_VOICE_ASSISTANT_STATUS
        let frame = buildBleFrame(commandId: CMD_SET_VOICE_ASSISTANT_STATUS, payload: [value])
        print("[validateSetVoiceAssistantStatus] Frame sent: " +
              frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(2))
        expectedResponseCommandId = nil
        if waitResult == .timedOut {
            print("[validateSetVoiceAssistantStatus] No ack within 2s (may be fire-and-forget, continuing)")
        } else {
            lastResponse = nil
        }
        return true
    }
}

// MARK: - Cancel commands during a real audio stream

extension BleProbe {

    /// EXPLORATORY: sends APP_CANCEL_VOICE_RECOGNITION (0x49) partway through a real
    /// DEVICE_PHOTO_RECOGNITION-triggered audio stream, to test whether this command actually
    /// halts the mic stream — the same kind of long-shot that turned
    /// APP_START_VOICE_RECOGNITION (0x57) and DEVICE_PHOTO_RECOGNITION (0x0A) themselves into
    /// confirmed, working triggers for the live microphone stream.
    func probeCancelVoiceRecognitionDuringStream() async -> Bool {
        return await probeCancelCommandDuringStream(
            label: "probeCancelVoiceRecognitionDuringStream",
            cancelCommandId: CMD_APP_CANCEL_VOICE_RECOGNITION,
            cancelPayload: [PARAM_VOICE_RECOGNITION_CANCEL]
        )
    }

    /// EXPLORATORY: same idea as probeCancelVoiceRecognitionDuringStream above, but with
    /// APP_CANCEL_AI_VOICE (0x51) — nominally meant to cancel the assistant's SPOKEN RESPONSE
    /// rather than the user's own speech capture, so it may have no effect at all on the
    /// incoming mic stream; tried anyway since both are equally unverified on real hardware.
    func probeCancelAiVoiceDuringStream() async -> Bool {
        return await probeCancelCommandDuringStream(
            label: "probeCancelAiVoiceDuringStream",
            cancelCommandId: CMD_APP_CANCEL_AI_VOICE,
            cancelPayload: [PARAM_AI_VOICE_CANCEL]
        )
    }

    /// Shared implementation for the two probes above: triggers a real audio stream via
    /// DEVICE_PHOTO_RECOGNITION (0x0A), waits `preCancelDelay` seconds (default 3s, enough for
    /// the wake-word beep and a few spoken words), sends the given cancel command, then
    /// observes for `postCancelObserveWindow` seconds (default 10s) whether audio packets keep
    /// arriving — reporting whether a genuine commandId 153 end-of-stream marker arrives, and
    /// how many packets arrived after the cancel command.
    private func probeCancelCommandDuringStream(
        label: String, cancelCommandId: UInt8, cancelPayload: [UInt8],
        preCancelDelay: TimeInterval = 3.0, postCancelObserveWindow: TimeInterval = 10.0
    ) async -> Bool {
        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic,
              characteristic.properties.contains(.write) else {
            print("[\(label)] Device or characteristic not available")
            return false
        }

        audioPackets = []
        wakeWordStartMarkerSeen = false
        voiceStreamEndMarkerSeen = false
        lastAudioPacketAt = nil
        isRecordingAudio = true

        let triggerFrame = buildBleFrame(commandId: CMD_DEVICE_PHOTO_RECOGNITION, payload: [0x00])
        print("[\(label)] Triggering stream via DEVICE_PHOTO_RECOGNITION: " +
              triggerFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(triggerFrame, for: characteristic, type: .withResponse)

        try? await Task.sleep(nanoseconds: UInt64(preCancelDelay * 1_000_000_000))
        let packetsBeforeCancel = audioPackets.count
        print("[\(label)] \(packetsBeforeCancel) audio packets received before sending the cancel command")

        let cancelFrame = buildBleFrame(commandId: cancelCommandId, payload: cancelPayload)
        print("[\(label)] Sending cancel command: " +
              cancelFrame.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(cancelFrame, for: characteristic, type: .withResponse)
        let cancelSentAt = Date()

        let pollInterval: TimeInterval = 0.25
        while Date().timeIntervalSince(cancelSentAt) < postCancelObserveWindow {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if voiceStreamEndMarkerSeen { break }
        }

        isRecordingAudio = false
        let packetsAfterCancel = audioPackets.count - packetsBeforeCancel

        print("[\(label)] Packets received AFTER the cancel command: \(packetsAfterCancel)")
        print("[\(label)] Genuine commandId 153 end-of-stream marker seen: \(voiceStreamEndMarkerSeen ? "yes" : "no")")
        if let lastPacket = lastAudioPacketAt {
            print("[\(label)] Last audio packet arrived \(String(format: "%.1f", Date().timeIntervalSince(lastPacket)))s ago")
        }

        let cancelAppearedToWork = packetsAfterCancel == 0 || voiceStreamEndMarkerSeen
        print("[\(label)] Conclusion: cancel command " +
              (cancelAppearedToWork ? "✅ appears to have stopped the stream" : "❌ had no observable effect — stream kept going"))

        return await finishAudioCapture(label: label)
    }
}

// MARK: - OPEN_WIFI media import

extension BleProbe {

    /// EXPLORATORY: sends OPEN_WIFI with the GET_WIFI_AP parameter (0x30) — access-point mode,
    /// matching this unit's hardware variant — and waits for the resulting
    /// APP_RECEIVE_WIFI_INFO (0x25/37) notification, decoding its SSID (a raw UTF-8 string, no
    /// further structure). Does NOT attempt to join the WiFi network or fetch the file list
    /// itself (this CLI has no WiFi-association capability) — that remains a manual follow-up
    /// step (join the SSID printed below using password "12345678", then GET
    /// http://192.168.169.1/app/getfilelist).
    func probeOpenWifiMediaImport() -> Bool {
        print("[probeOpenWifiMediaImport] Sending OPEN_WIFI (GET_WIFI_AP mode)...")

        guard let peripheral = connectingPeripheral, let characteristic = cmdWriteCharacteristic,
              characteristic.properties.contains(.write) else {
            print("[probeOpenWifiMediaImport] Device or characteristic not available")
            return false
        }

        drainStaleResponseSignal()
        expectedResponseCommandId = CMD_APP_RECEIVE_WIFI_INFO
        let frame = buildBleFrame(commandId: CMD_OPEN_WIFI, payload: [PARAM_GET_WIFI_AP])
        print("[probeOpenWifiMediaImport] Frame sent: " +
              frame.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)

        let waitResult = responseSemaphore.wait(timeout: .now() + .seconds(10))
        expectedResponseCommandId = nil

        guard waitResult != .timedOut, let responseData = lastResponse else {
            print("[probeOpenWifiMediaImport] No APP_RECEIVE_WIFI_INFO response within 10s")
            return false
        }
        lastResponse = nil

        guard let parsedFrame = parseBleFrame(data: responseData), parsedFrame.commandId == CMD_APP_RECEIVE_WIFI_INFO else {
            print("[probeOpenWifiMediaImport] Unexpected or unparseable response")
            return false
        }

        // The SSID has no defined field layout beyond "raw UTF-8 string" — strip any trailing
        // zero-padding before decoding, defensively, in case the device pads the payload.
        var payloadBytes = parsedFrame.payload
        while payloadBytes.last == 0 { payloadBytes.removeLast() }
        let ssid = String(bytes: payloadBytes, encoding: .utf8) ?? "(undecodable: \(payloadBytes))"

        print("[probeOpenWifiMediaImport] ✅ Glasses opened a WiFi access point, SSID: \"\(ssid)\"")
        print("[probeOpenWifiMediaImport] Manual next step: join this network (password \"12345678\"), " +
              "then GET http://192.168.169.1/app/getfilelist to list importable media")
        return true
    }
}

// MARK: - ACTION_SYNC passive listener

extension BleProbe {

    /// Passive instrumented listener for spontaneous ACTION_SYNC (0x45/69) pushes — checks the
    /// 10-boolean field order/semantics by prompting the tester to perform a sequence of
    /// physical actions and checking which ones produce a decoded flag. Sends NOTHING over
    /// BLE — purely observational, like validatePassiveWakeWordListen.
    func validateActionSyncPassiveListen(listenDuration: TimeInterval = 20.0) async -> Bool {
        print("""

        [validateActionSyncPassiveListen] This test sends NOTHING over BLE. It listens for \(Int(listenDuration))s \
        for spontaneous ACTION_SYNC notifications and decodes their flags.

        WHAT TO DO BEFORE YOU PRESS ENTER: during the listening window, try each of these in turn, \
        with a pause between each:
          1. Tap the glasses' touch surface once
          2. Nod your head while wearing the glasses (isNod)
          3. Shake your head while wearing the glasses (isShakeHand)
          4. Press the volume up / volume down controls, if present (isVolumeUp / isVolumeDown)
          5. Take the glasses off, then put them back on (isWear should change)
        Not all of these may actually produce an ACTION_SYNC push — that is itself useful information.
        """)
        print("[validateActionSyncPassiveListen] Press enter when ready to start listening...")
        _ = readLine()

        actionSyncFramesSeen = []
        isCapturingActionSync = true
        try? await Task.sleep(nanoseconds: UInt64(listenDuration * 1_000_000_000))
        isCapturingActionSync = false

        guard !actionSyncFramesSeen.isEmpty else {
            print("[validateActionSyncPassiveListen] No ACTION_SYNC notifications arrived during the window")
            return true
        }

        print("[validateActionSyncPassiveListen] Received \(actionSyncFramesSeen.count) ACTION_SYNC notification(s):")
        for (index, payload) in actionSyncFramesSeen.enumerated() {
            print("  #\(index + 1): \(decodeActionSyncFlags(payload))")
        }
        return true
    }
}

// MARK: - PHOTO_START size-discrepancy regression test

extension BleProbe {

    /// Regression/characterization test: two independent captures each showed the final JPEG
    /// exactly 500 bytes LARGER than the size PHOTO_START announced. Converts that ad-hoc
    /// 2-sample observation into a repeatable test — takes `iterations` photos in a row and
    /// checks whether the (actual - announced) delta is IDENTICAL across all of them.
    func validateTakePhotoSizeConsistency(iterations: Int = 3) -> Bool {
        print("[validateTakePhotoSizeConsistency] Taking \(iterations) photos in a row to characterize " +
              "the PHOTO_START size discrepancy...")

        var deltas: [Int] = []
        for i in 1...iterations {
            print("\n[validateTakePhotoSizeConsistency] --- Capture \(i)/\(iterations) ---")
            guard validateTakePhoto(), let expected = expectedPhotoSize else {
                print("[validateTakePhotoSizeConsistency] Capture \(i) failed or reported no expected size — aborting")
                return false
            }
            let delta = photoBuffer.count - expected
            deltas.append(delta)
            print("[validateTakePhotoSizeConsistency] Capture \(i): announced=\(expected) actual=\(photoBuffer.count) delta=\(delta)")

            if i < iterations {
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        let uniqueDeltas = Set(deltas)
        let consistent = uniqueDeltas.count == 1
        print("\n[validateTakePhotoSizeConsistency] Deltas across \(iterations) captures: \(deltas)")
        print("[validateTakePhotoSizeConsistency] " +
              (consistent ? "✅ Delta is CONSTANT (\(deltas.first ?? 0) bytes) across all captures"
                          : "❌ Delta VARIES across captures — the fixed one-chunk undercount hypothesis does not hold"))
        return consistent
    }
}
