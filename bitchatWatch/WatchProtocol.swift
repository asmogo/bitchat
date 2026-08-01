//
// WatchProtocol.swift
// bitchat
//
// Wire-protocol helpers, byte-compatible with:
// - iOS: bitchat/Protocols/Packets.swift (AnnouncementPacket TLV)
// - iOS: NoiseEncryptionService.signPacket (Ed25519 over toBinaryDataForSigning)
// - Android: shared BinaryProtocol/BitchatPacket sources used by :wear
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation

// MARK: - AnnouncementPacket (mirror of iOS Packets.swift — same TLV bytes)

struct WatchAnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data
    let signingPublicKey: Data
    let directNeighbors: [Data]?
    let capabilities: PeerCapabilities?

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case directNeighbors = 0x04
        case capabilities = 0x05
    }

    func encode() -> Data? {
        var data = Data()
        guard let nick = nickname.data(using: .utf8), nick.count <= 255 else { return nil }
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nick.count))
        data.append(nick)

        guard noisePublicKey.count == 32 else { return nil }
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        guard signingPublicKey.count == 32 else { return nil }
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)

        if let directNeighbors, !directNeighbors.isEmpty {
            let neighbors = Array(directNeighbors.prefix(10))
            guard neighbors.allSatisfy({ $0.count == 8 }) else { return nil }
            let encoded = neighbors.reduce(into: Data()) { result, peerID in
                result.append(peerID)
            }
            data.append(TLVType.directNeighbors.rawValue)
            data.append(UInt8(encoded.count))
            data.append(encoded)
        }

        if let capabilities {
            let encoded = capabilities.encoded()
            guard encoded.count <= 255 else { return nil }
            data.append(TLVType.capabilities.rawValue)
            data.append(UInt8(encoded.count))
            data.append(encoded)
        }
        return data
    }

    static func decode(from data: Data) -> WatchAnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?
        var capabilities: PeerCapabilities?

        while offset + 2 <= data.count {
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            switch type {
            case TLVType.nickname.rawValue:
                guard nickname == nil else { return nil }
                nickname = String(data: value, encoding: .utf8)
            case TLVType.noisePublicKey.rawValue:
                guard noisePublicKey == nil, value.count == 32 else { return nil }
                noisePublicKey = Data(value)
            case TLVType.signingPublicKey.rawValue:
                guard signingPublicKey == nil, value.count == 32 else { return nil }
                signingPublicKey = Data(value)
            case TLVType.directNeighbors.rawValue:
                guard directNeighbors == nil,
                      !value.isEmpty,
                      value.count <= 80,
                      value.count.isMultiple(of: 8) else { return nil }
                directNeighbors = stride(from: 0, to: value.count, by: 8).map { start in
                    Data(value[value.startIndex + start..<value.startIndex + start + 8])
                }
            case TLVType.capabilities.rawValue:
                guard capabilities == nil, !value.isEmpty, value.count <= 8 else { return nil }
                capabilities = PeerCapabilities(encoded: Data(value))
            default:
                continue // tolerant: skip future announcement extensions
            }
        }

        guard offset == data.count,
              let nickname, !nickname.isEmpty, nickname.count <= 50,
              nickname.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              let noisePublicKey,
              let signingPublicKey else { return nil }
        return WatchAnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: directNeighbors,
            capabilities: capabilities
        )
    }
}

// MARK: - Packet factory + Ed25519 packet signing (matches iOS signPacket)

enum WatchPacketFactory {

    /// Broadcast recipient = 8 x 0xFF (Android SpecialRecipients.BROADCAST).
    static let broadcastRecipient = Data(repeating: 0xFF, count: 8)
    static let messageTTL: UInt8 = 7 // AppConstants.MESSAGE_TTL_HOPS
    static let localCapabilities: PeerCapabilities = [
        .privateMedia,
        .privateMediaReceipts,
        .extendedFragmentSets
    ]

    static func sign(_ packet: BitchatPacket, with identity: WatchIdentity) -> BitchatPacket? {
        guard let unsigned = packet.toBinaryDataForSigning(),
              let signature = identity.sign(unsigned) else { return nil }
        var signed = packet
        signed.signature = signature
        return signed
    }

    /// Verify a packet signature against an announced Ed25519 signing key
    /// (same construction as iOS: signature over toBinaryDataForSigning()).
    static func verify(_ packet: BitchatPacket, signingPublicKey: Data) -> Bool {
        guard let signature = packet.signature,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else {
            return false
        }
        let unsigned = BitchatPacket(
            type: packet.type,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: nil,
            ttl: 0,
            version: packet.version,
            route: packet.route,
            isRSR: false
        )
        guard let data = unsigned.toBinaryDataForSigning() else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    static func announcePacket(
        identity: WatchIdentity,
        directNeighbors: [Data]
    ) -> BitchatPacket? {
        let announcement = WatchAnnouncementPacket(
            nickname: identity.nickname,
            noisePublicKey: identity.noisePublicKeyData,
            signingPublicKey: identity.signingPublicKeyData,
            directNeighbors: directNeighbors,
            capabilities: localCapabilities
        )
        guard let payload = announcement.encode() else { return nil }
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: identity.peerIDData,
            recipientID: nil,
            timestamp: nowMilliseconds(),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        return sign(packet, with: identity)
    }

    /// Public broadcast message — EXACTLY as iOS BLEService.sendMessage:
    /// type=message, recipientID=nil, payload = raw UTF-8 content, Ed25519-signed.
    /// (The wire carries no BitchatMessage structure for public mesh chat;
    /// sender identity comes from the packet signature + announced nickname.)
    static func publicMessagePacket(identity: WatchIdentity, content: String) -> BitchatPacket? {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: identity.peerIDData,
            recipientID: nil,
            timestamp: nowMilliseconds(),
            payload: Data(content.utf8),
            signature: nil,
            ttl: messageTTL
        )
        return sign(packet, with: identity)
    }

    /// Signed, ephemeral public PTT frame. It is deliberately not archived
    /// or gossip-synced; audio that cannot be heard now is stale.
    static func publicVoiceFramePacket(
        identity: WatchIdentity,
        payload: Data
    ) -> BitchatPacket? {
        guard !payload.isEmpty,
              payload.count <= TransportConfig.pttMaxBurstContentBytes else {
            return nil
        }
        let packet = BitchatPacket(
            type: MessageType.voiceFrame.rawValue,
            senderID: identity.peerIDData,
            recipientID: nil,
            timestamp: nowMilliseconds(),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        return sign(packet, with: identity)
    }

    static func noiseHandshakePacket(
        identity: WatchIdentity,
        recipient: PeerID,
        payload: Data
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: identity.peerIDData,
            recipientID: recipient.routingData,
            timestamp: nowMilliseconds(),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
    }

    static func noiseEncryptedPacket(
        identity: WatchIdentity,
        recipient: PeerID,
        ciphertext: Data
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: identity.peerIDData,
            recipientID: recipient.routingData,
            timestamp: nowMilliseconds(),
            payload: ciphertext,
            signature: nil,
            ttl: messageTTL
        )
    }

    static func requestSyncPacket(identity: WatchIdentity, payload: Data) -> BitchatPacket? {
        let packet = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: identity.peerIDData,
            recipientID: nil,
            timestamp: nowMilliseconds(),
            payload: payload,
            signature: nil,
            ttl: 0
        )
        return sign(packet, with: identity)
    }

    static func fileTransferPacket(
        identity: WatchIdentity,
        file: WatchFilePacket
    ) -> BitchatPacket? {
        guard let payload = file.encode() else { return nil }
        let packet = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: identity.peerIDData,
            recipientID: nil,
            timestamp: nowMilliseconds(),
            payload: payload,
            signature: nil,
            ttl: messageTTL,
            version: payload.count > Int(UInt16.max) ? 2 : 1
        )
        return sign(packet, with: identity)
    }

    /// Content-derived stable message ID, mirroring iOS MeshMessageIdentity.stableID
    /// (sha256 of "senderIDHex|timestampMs|trimmedContent", first 32 hex chars).
    static func stableMessageID(senderIDHex: String, timestampMs: UInt64, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = senderIDHex.lowercased() + "|" + String(timestampMs) + "|" + trimmed
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    static func nowMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    /// Bounds both old packets and packets dated too far into the future.
    /// Android applies a symmetric clock-skew check while learning an
    /// announcement identity. Future-dated packets must not remain admissible
    /// indefinitely merely because the local clock has not caught up yet.
    static func isStale(
        timestampMilliseconds: UInt64,
        nowMilliseconds now: UInt64 = nowMilliseconds(),
        maxAgeSeconds: UInt64 = 900,
        maxFutureSkewSeconds: UInt64 = 600
    ) -> Bool {
        if timestampMilliseconds >= now {
            return timestampMilliseconds - now > maxFutureSkewSeconds * 1_000
        }
        return now - timestampMilliseconds > maxAgeSeconds * 1_000
    }
}

// MARK: - Noise application payloads

enum WatchNoisePayloadType: UInt8 {
    case privateMessage = 0x01
    case readReceipt = 0x02
    case delivered = 0x03
    case voiceFrame = 0x08
    case privateFile = 0x20
    case authenticatedPeerState = 0x21
}

struct WatchPrivateMessagePacket {
    let messageID: String
    let content: String

    func encode() -> Data? {
        guard let id = messageID.data(using: .utf8), id.count <= 255,
              let content = content.data(using: .utf8), content.count <= 255 else {
            return nil
        }
        var data = Data([0x00, UInt8(id.count)])
        data.append(id)
        data.append(contentsOf: [0x01, UInt8(content.count)])
        data.append(content)
        return data
    }

    static func decode(_ data: Data) -> WatchPrivateMessagePacket? {
        var offset = 0
        var messageID: String?
        var content: String?
        while offset + 2 <= data.count {
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            let value = data[offset..<(offset + length)]
            offset += length
            switch type {
            case 0x00:
                guard messageID == nil else { return nil }
                messageID = String(data: value, encoding: .utf8)
            case 0x01:
                guard content == nil else { return nil }
                content = String(data: value, encoding: .utf8)
            default: return nil
            }
        }
        guard offset == data.count,
              let messageID, !messageID.isEmpty,
              let content else { return nil }
        return WatchPrivateMessagePacket(messageID: messageID, content: content)
    }
}

struct WatchAuthenticatedPeerStatePacket: Equatable {
    static let version: UInt8 = 1
    let capabilities: PeerCapabilities
    let signingPublicKey: Data

    func encode() -> Data? {
        guard signingPublicKey.count == 32 else { return nil }
        let capabilityBytes = capabilities.encoded()
        guard !capabilityBytes.isEmpty, capabilityBytes.count <= 8 else { return nil }
        var data = Data([Self.version, 0x01, UInt8(capabilityBytes.count)])
        data.append(capabilityBytes)
        data.append(contentsOf: [0x02, UInt8(signingPublicKey.count)])
        data.append(signingPublicKey)
        return data
    }

    static func decode(_ data: Data) -> WatchAuthenticatedPeerStatePacket? {
        guard data.first == version else { return nil }
        var offset = 1
        var capabilities: PeerCapabilities?
        var signingPublicKey: Data?
        while offset < data.count {
            guard offset + 2 <= data.count else { return nil }
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            let value = Data(data[offset..<(offset + length)])
            offset += length
            switch type {
            case 0x01:
                guard capabilities == nil, !value.isEmpty, value.count <= 8 else { return nil }
                let decoded = PeerCapabilities(encoded: value)
                guard decoded.encoded() == value else { return nil }
                capabilities = decoded
            case 0x02:
                guard signingPublicKey == nil, value.count == 32 else { return nil }
                signingPublicKey = value
            default:
                continue
            }
        }
        guard let capabilities, let signingPublicKey else { return nil }
        return WatchAuthenticatedPeerStatePacket(
            capabilities: capabilities,
            signingPublicKey: signingPublicKey
        )
    }
}

struct WatchFilePacket {
    var fileName: String?
    var fileSize: UInt64?
    var mimeType: String?
    var content: Data

    private enum TLVType: UInt8 {
        case fileName = 0x01
        case fileSize = 0x02
        case mimeType = 0x03
        case content = 0x04
    }

    func encode() -> Data? {
        let resolvedSize = fileSize ?? UInt64(content.count)
        guard FileTransferLimits.isValidPayload(content.count),
              content.count <= Int(UInt32.max),
              resolvedSize == UInt64(content.count),
              resolvedSize <= UInt64(UInt32.max) else { return nil }

        func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }

        var data = Data()
        if let fileName, let bytes = fileName.data(using: .utf8), bytes.count <= Int(UInt16.max) {
            data.append(TLVType.fileName.rawValue)
            appendBigEndian(UInt16(bytes.count), to: &data)
            data.append(bytes)
        }
        data.append(TLVType.fileSize.rawValue)
        appendBigEndian(UInt16(4), to: &data)
        appendBigEndian(UInt32(resolvedSize), to: &data)
        if let mimeType, let bytes = mimeType.data(using: .utf8), bytes.count <= Int(UInt16.max) {
            data.append(TLVType.mimeType.rawValue)
            appendBigEndian(UInt16(bytes.count), to: &data)
            data.append(bytes)
        }
        data.append(TLVType.content.rawValue)
        appendBigEndian(UInt32(content.count), to: &data)
        data.append(content)
        return data
    }

    static func decode(_ data: Data) -> WatchFilePacket? {
        var cursor = data.startIndex
        var fileName: String?
        var fileSize: UInt64?
        var mimeType: String?
        var content = Data()

        func readLength(_ bytes: Int, cursor: inout Data.Index) -> Int? {
            guard data.distance(from: cursor, to: data.endIndex) >= bytes else { return nil }
            var value: UInt64 = 0
            for _ in 0..<bytes {
                value = (value << 8) | UInt64(data[cursor])
                cursor = data.index(after: cursor)
            }
            return Int(exactly: value)
        }

        while cursor < data.endIndex {
            let rawType = data[cursor]
            cursor = data.index(after: cursor)
            let type = TLVType(rawValue: rawType)
            let length: Int?
            if type == .content {
                let snapshot = cursor
                if let canonical = readLength(4, cursor: &cursor),
                   canonical <= data.distance(from: cursor, to: data.endIndex) {
                    length = canonical
                } else {
                    cursor = snapshot
                    length = readLength(2, cursor: &cursor)
                }
            } else {
                length = readLength(2, cursor: &cursor)
            }
            guard let length, length >= 0,
                  data.distance(from: cursor, to: data.endIndex) >= length else {
                return nil
            }
            let end = data.index(cursor, offsetBy: length)
            let value = Data(data[cursor..<end])
            cursor = end
            switch type {
            case .fileName: fileName = String(data: value, encoding: .utf8)
            case .fileSize:
                guard value.count == 4 || value.count == 8 else { return nil }
                fileSize = value.reduce(0) { ($0 << 8) | UInt64($1) }
                guard fileSize.map({ $0 <= UInt64(FileTransferLimits.maxPayloadBytes) }) == true else {
                    return nil
                }
            case .mimeType: mimeType = String(data: value, encoding: .utf8)
            case .content:
                guard content.count + value.count <= FileTransferLimits.maxPayloadBytes else {
                    return nil
                }
                content.append(value)
            case nil: continue
            }
        }
        guard !content.isEmpty,
              FileTransferLimits.isValidPayload(content.count),
              fileSize == UInt64(content.count) else { return nil }
        return WatchFilePacket(
            fileName: fileName,
            fileSize: fileSize ?? UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
    }
}

// MARK: - Fragment assembly (mirror of iOS BLEFragmentHeader/AssemblyBuffer)

struct WatchFragmentHeader {
    let sender: UInt64
    let id: UInt64
    let index: Int
    let total: Int
    let originalType: UInt8
    let data: Data
    let isBroadcast: Bool

    init?(packet: BitchatPacket) {
        // 8 bytes ID + 2 index + 2 total + 1 type
        guard packet.payload.count > 13 else { return nil }

        var senderU64: UInt64 = 0
        for byte in packet.senderID.prefix(8) {
            senderU64 = (senderU64 << 8) | UInt64(byte)
        }
        var fragmentU64: UInt64 = 0
        for byte in packet.payload.prefix(8) {
            fragmentU64 = (fragmentU64 << 8) | UInt64(byte)
        }
        let index = Int((UInt16(packet.payload[8]) << 8) | UInt16(packet.payload[9]))
        let total = Int((UInt16(packet.payload[10]) << 8) | UInt16(packet.payload[11]))
        guard total > 0, total <= 10_000, index >= 0, index < total else { return nil }

        self.sender = senderU64
        self.id = fragmentU64
        self.index = index
        self.total = total
        self.originalType = packet.payload[12]
        self.data = Data(packet.payload.suffix(from: 13))
        self.isBroadcast = packet.recipientID == nil
            || packet.recipientID == WatchPacketFactory.broadcastRecipient
    }
}

final class WatchFragmentAssembler {
    enum AppendResult {
        case stored(received: Int, total: Int, started: Bool)
        case complete(Data)
        case rejected(reason: String)
    }

    private struct Key: Hashable {
        let sender: UInt64
        let id: UInt64
    }
    private struct Buffer {
        var total: Int
        var originalType: UInt8
        var parts: [Int: Data]
        var byteCount: Int
        var createdAt: Date
        var lastNewPartAt: Date
        var lastResyncAt: Date?
        var isBroadcast: Bool
    }

    private var buffers: [Key: Buffer] = [:]
    private var totalBufferedBytes = 0
    private let maxBufferedBytes = FileTransferLimits.maxFramedFileBytes * 4
    // Match Android's receiver. A public sync burst can interleave fragments
    // from many transfers; evicting an active set makes every stream thrash.
    private let maxInFlightAssemblies = 64

    func append(_ header: WatchFragmentHeader) -> AppendResult {
        let key = Key(sender: header.sender, id: header.id)
        let started = buffers[key] == nil
        if started, buffers.count >= maxInFlightAssemblies {
            evictOldest(excluding: key)
        }
        var buffer = buffers[key] ?? Buffer(
            total: header.total,
            originalType: header.originalType,
            parts: [:],
            byteCount: 0,
            createdAt: Date(),
            lastNewPartAt: Date(),
            lastResyncAt: nil,
            isBroadcast: header.isBroadcast
        )
        guard buffer.total == header.total,
              buffer.originalType == header.originalType,
              buffer.isBroadcast == header.isBroadcast else {
            removeBuffer(for: key)
            return .rejected(reason: "inconsistent fragment metadata")
        }

        if let existing = buffer.parts[header.index], existing != header.data {
            removeBuffer(for: key)
            return .rejected(reason: "conflicting duplicate fragment")
        }
        let madeProgress = buffer.parts[header.index] == nil
        let byteDelta = madeProgress ? header.data.count : 0
        let assemblyLimit = Self.assemblyLimit(for: header.originalType)
        guard buffer.byteCount <= assemblyLimit - byteDelta else {
            removeBuffer(for: key)
            return .rejected(reason: "assembled payload exceeds \(assemblyLimit)B")
        }
        while totalBufferedBytes > maxBufferedBytes - byteDelta,
              evictOldest(excluding: key) {}
        guard totalBufferedBytes <= maxBufferedBytes - byteDelta else {
            removeBuffer(for: key)
            return .rejected(reason: "fragment buffer memory limit")
        }

        buffer.parts[header.index] = header.data
        if madeProgress {
            buffer.byteCount += byteDelta
            totalBufferedBytes += byteDelta
            buffer.lastNewPartAt = Date()
        }
        buffers[key] = buffer

        guard buffer.parts.count == buffer.total else {
            return .stored(received: buffer.parts.count, total: buffer.total, started: started)
        }
        var assembled = Data()
        for index in 0..<buffer.total {
            guard let part = buffer.parts[index] else {
                removeBuffer(for: key)
                return .rejected(reason: "missing fragment \(index)")
            }
            assembled.append(part)
        }
        removeBuffer(for: key)
        return .complete(assembled)
    }

    var hasActiveAssemblies: Bool {
        !buffers.isEmpty
    }

    func stalledBroadcastFragmentIDs(
        stalledAfter: TimeInterval,
        retryAfter: TimeInterval,
        limit: Int,
        now: Date = Date()
    ) -> [Data] {
        let candidates = buffers
            .filter { _, buffer in
                guard buffer.isBroadcast,
                      now.timeIntervalSince(buffer.lastNewPartAt) >= stalledAfter else {
                    return false
                }
                if let lastResyncAt = buffer.lastResyncAt {
                    return now.timeIntervalSince(lastResyncAt) >= retryAfter
                }
                return true
            }
            .sorted { lhs, rhs in
                lhs.value.lastNewPartAt < rhs.value.lastNewPartAt
            }
            .prefix(max(0, limit))

        return candidates.map { key, _ in
            buffers[key]?.lastResyncAt = now
            var bigEndianID = key.id.bigEndian
            return withUnsafeBytes(of: &bigEndianID) { Data($0) }
        }
    }

    func expire(olderThan seconds: TimeInterval = 30) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let expired = buffers.compactMap { key, buffer in
            buffer.createdAt <= cutoff ? key : nil
        }
        for key in expired {
            removeBuffer(for: key)
        }
    }

    @discardableResult
    private func evictOldest(excluding excludedKey: Key) -> Bool {
        guard let oldest = buffers
            .filter({ $0.key != excludedKey })
            .min(by: { $0.value.lastNewPartAt < $1.value.lastNewPartAt })?
            .key else { return false }
        removeBuffer(for: oldest)
        return true
    }

    private func removeBuffer(for key: Key) {
        guard let removed = buffers.removeValue(forKey: key) else { return }
        totalBufferedBytes = max(0, totalBufferedBytes - removed.byteCount)
    }

    private static func assemblyLimit(for originalType: UInt8) -> Int {
        if originalType == MessageType.fileTransfer.rawValue
            || originalType == MessageType.noiseEncrypted.rawValue {
            return FileTransferLimits.maxFramedFileBytes
        }
        return FileTransferLimits.maxPayloadBytes
    }
}

enum WatchRequestSyncPacket {
    private static let fragmentTypeFlag = Data([1 << 5])
    private static let maxFragmentIDs = 60

    static func fragmentRecoveryPayload(fragmentIDs: [Data]) -> Data? {
        let tokens = fragmentIDs
            .filter { $0.count == 8 }
            .prefix(maxFragmentIDs)
            .map { data in
                data.map { String(format: "%02x", $0) }.joined()
            }
        guard !tokens.isEmpty else { return nil }

        var payload = Data()
        appendTLV(type: 0x01, value: Data([10]), to: &payload) // GCS P
        appendTLV(type: 0x02, value: Data([0, 0, 0, 1]), to: &payload) // GCS M
        appendTLV(type: 0x03, value: Data(), to: &payload) // empty local filter
        appendTLV(type: 0x04, value: fragmentTypeFlag, to: &payload)
        appendTLV(type: 0x06, value: Data(tokens.joined(separator: ",").utf8), to: &payload)
        return payload
    }

    private static func appendTLV(type: UInt8, value: Data, to payload: inout Data) {
        guard value.count <= Int(UInt16.max) else { return }
        payload.append(type)
        payload.append(UInt8((value.count >> 8) & 0xFF))
        payload.append(UInt8(value.count & 0xFF))
        payload.append(value)
    }
}
