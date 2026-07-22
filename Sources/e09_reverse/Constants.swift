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

// MARK: - Eyevue BLE Protocol Constants

// Service and Characteristic UUIDs
public let UUID_SERVICE = CBUUID(string: "0000aa12-0000-1000-8000-00805F9B34FB")
public let UUID_CMD_WRITE = CBUUID(string: "0000aa13-0000-1000-8000-00805F9B34FB")
public let UUID_CMD_NOTIFY = CBUUID(string: "0000aa14-0000-1000-8000-00805F9B34FB")
public let UUID_PHOTO_NOTIFY = CBUUID(string: "0000aa15-0000-1000-8000-00805F9B34FB")
public let UUID_2902 = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

// Command codes
public let CMD_GET_BATTERY: UInt8 = 0x17
public let CMD_GET_CAPACITY: UInt8 = 0x16
public let CMD_VOICE_COMMAND: UInt8 = 0x06
public let CMD_RECORD_AUDIO: UInt8 = 0x34
public let CMD_TAKE_PHOTO: UInt8 = 0x22
public let CMD_GET_DEVICE_INFO: UInt8 = 0x55
public let CMD_GET_SUPPORT_FUNCTION: UInt8 = 0x95
public let CMD_GET_VOICE_ASSISTANT_STATUS: UInt8 = 0x71
public let CMD_APP_RECEIVE_VOICE_DATA: UInt8 = 0x46

// Experimental-probe-only command codes
public let CMD_APP_START_VOICE_RECOGNITION: UInt8 = 0x57
public let CMD_APP_STOP_VOICE_RECOGNITION: UInt8 = 0x56
public let CMD_DEVICE_PHOTO_RECOGNITION: UInt8 = 0x0A

// Wake word and voice stream constants
public let CMD_WAKE_WORD_START: UInt8 = 0x97
public let CMD_VOICE_STREAM_END: UInt8 = 0x99

// File-transfer protocol (photo capture) command codes
public let CMD_PHOTO_START: UInt8 = 0x97
public let CMD_PHOTO_TRANS: UInt8 = 0x98
public let CMD_PHOTO_END: UInt8 = 0x99

// Command Parameters
public let PARAM_BATTERY_CAPACITY: UInt8 = 0x00
public let PARAM_VOICE_COMMAND_ON: UInt8 = 0x31
public let PARAM_VOICE_COMMAND_OFF: UInt8 = 0x30
public let PARAM_RECORD_AUDIO_START: UInt8 = 0x01
public let PARAM_RECORD_AUDIO_END: UInt8 = 0x00
public let PARAM_TAKE_PHOTO_HIGH_QUALITY: UInt8 = 0x31
public let PARAM_TAKE_PHOTO_THUMBNAIL: UInt8 = 0x30
public let PARAM_VOICE_RECOGNITION_CANCEL: UInt8 = 0x00
public let PARAM_AI_VOICE_CANCEL: UInt8 = 0x01
public let PARAM_GET_WIFI_AP: UInt8 = 0x30
public let PARAM_GET_WIFI_P2P: UInt8 = 0x31

// Start of Frame (SOF) markers
public let SOF_APP_BLE: [UInt8] = [0xAB, 0x55]
public let SOF_BLE_APP: [UInt8] = [0xAC, 0x55]

// Additional command codes for extended validation coverage (see VALIDATION_PLAN.md)
public let CMD_SET_VOICE_ASSISTANT_STATUS: UInt8 = 0x72
public let CMD_APP_CANCEL_VOICE_RECOGNITION: UInt8 = 0x49
public let CMD_APP_CANCEL_AI_VOICE: UInt8 = 0x51
public let CMD_OPEN_WIFI: UInt8 = 0x39
public let CMD_APP_RECEIVE_WIFI_INFO: UInt8 = 0x25
public let CMD_ACTION_SYNC: UInt8 = 0x45

// Scan duration
public let scanDuration: TimeInterval = 20