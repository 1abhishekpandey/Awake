import CommonCrypto
import Foundation

/// Builds and reads Tuya local-protocol v3.3 frames. Pure: no sockets, no clock,
/// so it is unit tested against frames produced by tinytuya.
///
/// A frame is: prefix `000055AA`, sequence number, command, length, payload,
/// CRC32, suffix `0000AA55` (all integers big-endian `UInt32`). `length` counts
/// the payload plus CRC plus suffix. Replies from the plug also carry a 4-byte
/// return code before the payload.
enum TuyaProtocol {
    enum Command: UInt32 {
        case control = 7
        case query = 10
    }

    enum ProtocolError: Error, Equatable {
        case badFrame
        case badChecksum
        case decryptFailed
    }

    static let headerLength = 16
    private static let prefix: UInt32 = 0x0000_55AA
    private static let suffix: UInt32 = 0x0000_AA55
    /// v3.3 prefixes CONTROL payloads with the version and 12 zero bytes.
    private static let versionHeader = Data("3.3".utf8) + Data(count: 12)

    // MARK: Requests

    static func queryFrame(deviceID: String, key: Data, time: Int, sequence: UInt32) -> Data {
        let json = #"{"gwId":"\#(deviceID)","devId":"\#(deviceID)","uid":"\#(deviceID)","t":"\#(time)"}"#
        return frame(command: .query, payload: encrypt(Data(json.utf8), key: key), sequence: sequence)
    }

    static func controlFrame(deviceID: String, key: Data, switchDP: Int, on: Bool, time: Int, sequence: UInt32) -> Data {
        let json = #"{"devId":"\#(deviceID)","uid":"\#(deviceID)","t":"\#(time)","dps":{"\#(switchDP)":\#(on)}}"#
        return frame(command: .control, payload: versionHeader + encrypt(Data(json.utf8), key: key), sequence: sequence)
    }

    static func frame(command: Command, payload: Data, sequence: UInt32) -> Data {
        var data = Data()
        data.appendUInt32(prefix)
        data.appendUInt32(sequence)
        data.appendUInt32(command.rawValue)
        data.appendUInt32(UInt32(payload.count + 8))
        data.append(payload)
        data.appendUInt32(crc32(data))
        data.appendUInt32(suffix)
        return data
    }

    // MARK: Replies

    /// Total frame size announced by a 16-byte header, or nil if it is not a Tuya header.
    static func frameLength(header: Data) -> Int? {
        guard header.count >= headerLength, header.uint32(at: 0) == prefix else { return nil }
        return headerLength + Int(header.uint32(at: 12))
    }

    /// Decodes a complete reply frame into its JSON object, or nil for an empty
    /// acknowledgement (the plug answers CONTROL with no payload).
    static func decodeReply(_ frame: Data, key: Data) throws -> [String: Any]? {
        guard frame.count >= headerLength + 12, frame.uint32(at: 0) == prefix,
              frame.uint32(at: frame.count - 4) == suffix
        else { throw ProtocolError.badFrame }
        guard crc32(frame.prefix(frame.count - 8)) == frame.uint32(at: frame.count - 8) else {
            throw ProtocolError.badChecksum
        }
        // Skip the return code; drop CRC and suffix.
        var payload = Data(frame[(frame.startIndex + headerLength + 4)..<(frame.endIndex - 8)])
        if payload.isEmpty { return nil }
        if payload.starts(with: Data("3.3".utf8)) { payload = payload.dropFirst(versionHeader.count) }
        guard let plain = decrypt(Data(payload), key: key) else { throw ProtocolError.decryptFailed }
        return try JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    // MARK: Crypto

    static func encrypt(_ data: Data, key: Data) -> Data {
        crypt(CCOperation(kCCEncrypt), data, key: key) ?? Data()
    }

    static func decrypt(_ data: Data, key: Data) -> Data? {
        crypt(CCOperation(kCCDecrypt), data, key: key)
    }

    /// AES-128-ECB with PKCS7 padding, which is what v3.3 uses.
    private static func crypt(_ operation: CCOperation, _ data: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, nil,
                        dataBytes.baseAddress, data.count,
                        outBytes.baseAddress, outCapacity, &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32<D: DataProtocol>(_ data: D) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
