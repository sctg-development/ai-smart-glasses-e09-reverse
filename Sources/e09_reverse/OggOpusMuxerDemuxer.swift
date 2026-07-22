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

// MARK: - Ogg/Opus Muxing
//
// The glasses' microphone audio (APP_RECEIVE_VOICE_DATA / commandId 0x46) arrives over BLE as
// a sequence of raw, elementary Opus packets — there is no container around them. A bare
// concatenation of those packets is NOT a playable file: common audio players/frameworks expect
// Opus inside an Ogg container (RFC 7845, "Ogg Opus"), starting with an OpusHead identification
// page and an OpusTags comment page.
//
// This is a minimal but spec-compliant Ogg Opus muxer: one Opus packet per Ogg page (simpler and
// always safe here since these packets are tiny — well under the 255-byte single-segment limit
// — unlike production encoders, which pack many packets per page for efficiency). Granule
// positions (used by players for seeking/duration) are computed exactly from each packet's TOC
// (table-of-contents) byte per RFC 6716 §3.1, not guessed.
public enum OggOpusMuxer {
    /// Ogg's CRC-32 variant (used by libogg): polynomial 0x04C11DB7, computed MSB-first
    /// (un-reflected), initial value 0, no final XOR — different from the common zlib/CRC-32
    /// (which is bit-reflected with polynomial 0xEDB88320). Getting this wrong produces a page
    /// checksum mismatch that strict Ogg readers reject outright.
    static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i) << 24
            for _ in 0..<8 {
                if crc & 0x8000_0000 != 0 {
                    crc = (crc << 1) ^ 0x04C1_1DB7
                } else {
                    crc = crc << 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            let index = Int((crc >> 24) ^ UInt32(byte)) & 0xFF
            crc = (crc << 8) ^ crcTable[index]
        }
        return crc
    }

    /// Per RFC 6716 §3.1 Table 2: Opus frame duration in milliseconds, indexed by the 5-bit
    /// "config" number extracted from a packet's TOC byte (configs 0-31).
    static let configFrameDurationMs: [Double] = [
        10, 20, 40, 60,   // 0-3:   SILK-only, narrowband
        10, 20, 40, 60,   // 4-7:   SILK-only, mediumband
        10, 20, 40, 60,   // 8-11:  SILK-only, wideband
        10, 20,           // 12-13: Hybrid, super-wideband
        10, 20,           // 14-15: Hybrid, fullband
        2.5, 5, 10, 20,   // 16-19: CELT-only, narrowband
        2.5, 5, 10, 20,   // 20-23: CELT-only, wideband
        2.5, 5, 10, 20,   // 24-27: CELT-only, super-wideband
        2.5, 5, 10, 20,   // 28-31: CELT-only, fullband
    ]

    /// Number of 48kHz samples represented by one Opus packet, decoded from its TOC byte (and,
    /// for "code 3" packets, the frame-count byte that immediately follows it) per RFC 6716 §3.1.
    /// Ogg Opus granule positions are always expressed at a fixed 48kHz reference rate regardless
    /// of the stream's actual encoded sample rate.
    public static func packetDurationIn48kSamples(_ packet: [UInt8]) -> Int64 {
        guard let toc = packet.first else { return 0 }
        let config = Int((toc >> 3) & 0x1F)
        let frameCountCode = toc & 0x03
        let frameDurationMs = configFrameDurationMs[config]

        let frameCount: Int
        switch frameCountCode {
        case 0: frameCount = 1                                    // 1 frame
        case 1, 2: frameCount = 2                                 // 2 frames (equal or differing size)
        default:                                                  // code 3: arbitrary count byte follows the TOC
            if packet.count >= 2 {
                frameCount = Int(packet[1] & 0x3F)
            } else {
                frameCount = 1
            }
        }

        return Int64((frameDurationMs * Double(frameCount) * 48000.0 / 1000.0).rounded())
    }

    /// Builds one complete Ogg page (RFC 3533) wrapping a single packet.
     static func buildPage(
        headerType: UInt8, granulePosition: Int64, serialNumber: UInt32,
        sequenceNumber: UInt32, packet: [UInt8]
    ) -> [UInt8] {
        // Lacing values: sequences of 255 mean "the packet continues for another 255 bytes";
        // a final value < 255 (which may be 0) terminates it. Our packets are always small
        // enough that this loop runs at most a couple of times, but it's written generically.
        var segmentTable: [UInt8] = []
        var remaining = packet.count
        while remaining >= 255 {
            segmentTable.append(255)
            remaining -= 255
        }
        segmentTable.append(UInt8(remaining))

        var header: [UInt8] = []
        header.append(contentsOf: Array("OggS".utf8))
        header.append(0)  // stream_structure_version
        header.append(headerType)
        for i in 0..<8 { header.append(UInt8((UInt64(bitPattern: Int64(granulePosition)) >> (8 * i)) & 0xFF)) }
        for i in 0..<4 { header.append(UInt8((serialNumber >> (8 * i)) & 0xFF)) }
        for i in 0..<4 { header.append(UInt8((sequenceNumber >> (8 * i)) & 0xFF)) }
        header.append(contentsOf: [0, 0, 0, 0])  // checksum placeholder, filled in below
        header.append(UInt8(segmentTable.count))
        header.append(contentsOf: segmentTable)

        var page = header + packet
        let checksum = crc32(page)
        // Checksum field is written little-endian, even though the CRC itself is computed
        // MSB-first — this matches libogg's on-disk format exactly.
        page[22] = UInt8(checksum & 0xFF)
        page[23] = UInt8((checksum >> 8) & 0xFF)
        page[24] = UInt8((checksum >> 16) & 0xFF)
        page[25] = UInt8((checksum >> 24) & 0xFF)
        return page
    }

    /// Builds a complete, playable Ogg Opus file (RFC 7845) from a sequence of raw Opus packets.
    /// - Parameters:
    ///   - packets: Opus packets in stream order, one per received BLE audio notification.
    ///   - inputSampleRate: the original capture rate (informational field in the ID header only
    ///     — Ogg Opus streams are always logically 48kHz; this does not resample anything).
    ///   - channelCount: 1 (mono) or 2 (stereo).
    public static func buildFile(packets: [[UInt8]], inputSampleRate: UInt32 = 16000, channelCount: UInt8 = 1) -> Data {
        let serialNumber: UInt32 = 0x4559_5645  // arbitrary constant ("EYVE"), fine for a single-stream file
        var sequenceNumber: UInt32 = 0
        var output = Data()

        // Page 0: OpusHead identification header (RFC 7845 §5.1). Granule position is 0 and this
        // is the only page marked "beginning of stream" (header_type bit 0x02).
        var opusHead: [UInt8] = Array("OpusHead".utf8)
        opusHead.append(1)                                   // version
        opusHead.append(channelCount)
        opusHead.append(contentsOf: [0, 0])                  // pre-skip (no encoder priming to trim)
        for i in 0..<4 { opusHead.append(UInt8((inputSampleRate >> (8 * i)) & 0xFF)) }
        opusHead.append(contentsOf: [0, 0])                  // output gain (Q7.8, 0 = no adjustment)
        opusHead.append(0)                                   // channel mapping family 0 (mono/stereo, no surround)
        output.append(contentsOf: buildPage(
            headerType: 0x02, granulePosition: 0, serialNumber: serialNumber,
            sequenceNumber: sequenceNumber, packet: opusHead))
        sequenceNumber += 1

        // Page 1: OpusTags comment header (RFC 7845 §5.2) — vendor string, no user comments.
        let vendor = Array("ble_probe (EYEVUE_1.0.65-gp reverse-engineering)".utf8)
        var opusTags: [UInt8] = Array("OpusTags".utf8)
        let vendorLen = UInt32(vendor.count)
        for i in 0..<4 { opusTags.append(UInt8((vendorLen >> (8 * i)) & 0xFF)) }
        opusTags.append(contentsOf: vendor)
        opusTags.append(contentsOf: [0, 0, 0, 0])            // user_comment_list_length = 0
        output.append(contentsOf: buildPage(
            headerType: 0x00, granulePosition: 0, serialNumber: serialNumber,
            sequenceNumber: sequenceNumber, packet: opusTags))
        sequenceNumber += 1

        // One data page per Opus packet, with an exact running granule position computed from
        // each packet's own TOC byte. The final page is marked "end of stream" (0x04).
        var granulePosition: Int64 = 0
        for (index, packet) in packets.enumerated() {
            guard !packet.isEmpty else { continue }
            granulePosition += packetDurationIn48kSamples(packet)
            let isLast = index == packets.count - 1
            output.append(contentsOf: buildPage(
                headerType: isLast ? 0x04 : 0x00, granulePosition: granulePosition,
                serialNumber: serialNumber, sequenceNumber: sequenceNumber, packet: packet))
            sequenceNumber += 1
        }

        return output
    }
}

// MARK: - Ogg/Opus Demuxing

/// Errors thrown while parsing an Ogg Opus container back into elementary Opus packets.
public enum OggOpusDemuxError: LocalizedError {
    case invalidCapturePattern
    case truncatedPage
    case notOpusStream
    case missingOpusHead

    public var errorDescription: String? {
        switch self {
        case .invalidCapturePattern:
            return "Invalid Ogg page: missing 'OggS' capture pattern"
        case .truncatedPage:
            return "Truncated Ogg page: declared segment/payload length exceeds available data"
        case .notOpusStream:
            return "First packet of the logical stream is not an OpusHead identification header"
        case .missingOpusHead:
            return "Ogg stream ended before an OpusHead identification header was found"
        }
    }
}

/// Parsed contents of the RFC 7845 §5.1 "OpusHead" identification header.
public struct OggOpusStreamInfo {
    public let version: UInt8
    public let channelCount: Int
    public let preSkipSamples: UInt16
    public let inputSampleRate: UInt32
    public let outputGain: Int16
    public let channelMappingFamily: UInt8
}

/// Result of demuxing a complete Ogg Opus file: the parsed identification header plus the
/// elementary Opus packets in stream order, with the OpusHead/OpusTags framing removed.
public struct OggOpusDemuxResult {
    public let header: OggOpusStreamInfo
    public let packets: [[UInt8]]
}

/// Minimal but spec-compliant Ogg Opus demuxer — the counterpart to `OggOpusMuxer` above. Parses
/// Ogg pages (RFC 3533) generically (including multi-segment pages and packets that span more
/// than one page via lacing continuation), then strips the two Ogg Opus header packets (RFC 7845
/// §5.1 OpusHead, §5.2 OpusTags) to recover the raw elementary Opus audio packets that
/// `OpusDecoder` expects, e.g. for re-decoding a `passiveWakeWordListen.ogg` file captured by
/// `BleProbe` back to PCM for offline VAD testing.
public enum OggOpusDemuxer {
    /// Splits raw bytes into complete Ogg pages, decoding each page's segment table into
    /// individual packet fragments and re-assembling packets that are "continued" across pages
    /// (per RFC 3533 §6, header_type bit 0x01) before handing them to `body`.
    public static func demux(_ data: Data) throws -> OggOpusDemuxResult {
        var header: OggOpusStreamInfo?
        var packets: [[UInt8]] = []
        var pendingPacket: [UInt8] = []

        let bytes = [UInt8](data)
        let count = bytes.count
        var offset = 0

        while offset < count {
            guard offset + 27 <= count else { break }
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67,
                  bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                throw OggOpusDemuxError.invalidCapturePattern
            }

            let headerType = bytes[offset + 5]
            let segmentCount = Int(bytes[offset + 26])
            let segmentTableStart = offset + 27
            guard segmentTableStart + segmentCount <= count else {
                throw OggOpusDemuxError.truncatedPage
            }
            let segmentTable = Array(bytes[segmentTableStart..<(segmentTableStart + segmentCount)])

            let payloadStart = segmentTableStart + segmentCount
            let payloadLength = segmentTable.reduce(0) { $0 + Int($1) }
            guard payloadStart + payloadLength <= count else {
                throw OggOpusDemuxError.truncatedPage
            }
            let payload = Array(bytes[payloadStart..<(payloadStart + payloadLength)])

            // A page whose header_type has bit 0x01 set means its FIRST packet fragment is a
            // continuation of a packet started on the previous page — everything else about
            // segmenting is identical. We don't need to special-case this explicitly: we simply
            // keep appending fragments onto `pendingPacket` until a lacing value < 255
            // terminates a packet, regardless of which page(s) its fragments came from.
            _ = headerType

            var segmentIndex = 0
            var fragmentStart = 0
            while segmentIndex < segmentTable.count {
                var fragmentLength = 0
                var isTerminated = false
                while segmentIndex < segmentTable.count {
                    let lacingValue = Int(segmentTable[segmentIndex])
                    fragmentLength += lacingValue
                    segmentIndex += 1
                    if lacingValue < 255 {
                        isTerminated = true
                        break
                    }
                }
                let fragment = Array(payload[fragmentStart..<(fragmentStart + fragmentLength)])
                fragmentStart += fragmentLength
                pendingPacket.append(contentsOf: fragment)

                if isTerminated {
                    let completedPacket = pendingPacket
                    pendingPacket = []
                    try handleCompletedPacket(completedPacket, header: &header, packets: &packets)
                }
                // else: packet continues onto the next page — leave it in `pendingPacket`.
            }

            offset = payloadStart + payloadLength
        }

        guard let resolvedHeader = header else {
            throw OggOpusDemuxError.missingOpusHead
        }
        return OggOpusDemuxResult(header: resolvedHeader, packets: packets)
    }

    /// Convenience overload matching `OggOpusMuxer.buildFile`'s packet-only use case: demuxes and
    /// returns just the elementary Opus audio packets, discarding the parsed header.
    public static func extractPackets(from data: Data) throws -> [[UInt8]] {
        return try demux(data).packets
    }

    private static func handleCompletedPacket(
        _ packet: [UInt8], header: inout OggOpusStreamInfo?, packets: inout [[UInt8]]
    ) throws {
        let opusHeadMagic = Array("OpusHead".utf8)
        let opusTagsMagic = Array("OpusTags".utf8)

        if header == nil {
            // The very first packet of the logical stream MUST be the OpusHead ID header.
            guard packet.count >= 19, Array(packet[0..<8]) == opusHeadMagic else {
                throw OggOpusDemuxError.notOpusStream
            }
            let version = packet[8]
            let channelCount = Int(packet[9])
            let preSkip = UInt16(packet[10]) | (UInt16(packet[11]) << 8)
            let inputSampleRate = UInt32(packet[12]) | (UInt32(packet[13]) << 8)
                | (UInt32(packet[14]) << 16) | (UInt32(packet[15]) << 24)
            let outputGain = Int16(bitPattern: UInt16(packet[16]) | (UInt16(packet[17]) << 8))
            let channelMappingFamily = packet[18]
            header = OggOpusStreamInfo(
                version: version, channelCount: channelCount, preSkipSamples: preSkip,
                inputSampleRate: inputSampleRate, outputGain: outputGain,
                channelMappingFamily: channelMappingFamily)
            return
        }

        if packet.count >= 8, Array(packet[0..<8]) == opusTagsMagic {
            // OpusTags comment header — not audio, discard.
            return
        }

        // Everything else is an elementary Opus audio packet, in stream order.
        packets.append(packet)
    }
}
