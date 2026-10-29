//
// WatchGossipSync.swift
// bitchat
//

import BitFoundation
import CryptoKit
import Foundation

struct WatchSyncCandidate: Equatable {
    let packetID: Data
    let timestamp: UInt64
}

struct WatchSyncRequest {
    let p: Int
    let m: UInt32
    let data: Data
    let typeBits: UInt64
    let sinceTimestamp: UInt64?
    let fragmentIDs: Set<Data>?

    static func decode(_ data: Data, maximumValueBytes: Int = 1_024) -> WatchSyncRequest? {
        var offset = 0
        var p: Int?
        var m: UInt32?
        var filter: Data?
        var typeBits: UInt64 = 0x03
        var since: UInt64?
        var fragmentIDs: Set<Data>?

        while offset + 3 <= data.count {
            let type = data[offset]
            let length = (Int(data[offset + 1]) << 8) | Int(data[offset + 2])
            offset += 3
            guard length <= maximumValueBytes, offset + length <= data.count else {
                return nil
            }
            let value = Data(data[offset..<(offset + length)])
            offset += length
            switch type {
            case 0x01 where value.count == 1:
                p = Int(value[0])
            case 0x02 where value.count == 4:
                m = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            case 0x03:
                filter = value
            case 0x04 where (1...8).contains(value.count):
                typeBits = value.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << UInt64($1.offset * 8))
                }
            case 0x05 where value.count == 8:
                since = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case 0x06:
                fragmentIDs = decodeFragmentIDs(value)
            default:
                break
            }
        }
        guard offset == data.count, let p, (1...32).contains(p),
              let m, m > 0, let filter else { return nil }
        return WatchSyncRequest(
            p: p,
            m: m,
            data: filter,
            typeBits: typeBits,
            sinceTimestamp: since,
            fragmentIDs: fragmentIDs
        )
    }

    static func publicPayload(packetIDs: [Data], sinceTimestamp: UInt64? = nil) -> Data {
        let parameters = WatchGCS.build(ids: packetIDs, maxBytes: 400, p: 7)
        return publicPayload(parameters: parameters, sinceTimestamp: sinceTimestamp)
    }

    /// Builds a filter and an exact coverage cursor. When the 400-byte GCS
    /// cannot hold every local ID, the cursor advances to the oldest packet
    /// actually represented by the filter so responders do not resend the
    /// uncovered tail forever.
    static func publicPayload(
        candidates: [WatchSyncCandidate],
        minimumTimestamp: UInt64?
    ) -> Data {
        let parameters = WatchGCS.build(
            ids: candidates.map(\.packetID),
            maxBytes: 400,
            p: 7
        )
        let coverageTimestamp: UInt64?
        if parameters.includedCount > 0,
           parameters.includedCount < candidates.count {
            coverageTimestamp = candidates[parameters.includedCount - 1].timestamp
        } else {
            coverageTimestamp = nil
        }
        let sinceTimestamp = [minimumTimestamp, coverageTimestamp]
            .compactMap { $0 }
            .max()
        return publicPayload(
            parameters: parameters,
            sinceTimestamp: sinceTimestamp
        )
    }

    private static func publicPayload(
        parameters: WatchGCS.Parameters,
        sinceTimestamp: UInt64?
    ) -> Data {
        var payload = Data()
        append(type: 0x01, value: Data([UInt8(parameters.p)]), to: &payload)
        var m = parameters.m.bigEndian
        append(type: 0x02, value: withUnsafeBytes(of: &m) { Data($0) }, to: &payload)
        append(type: 0x03, value: parameters.data, to: &payload)
        append(type: 0x04, value: Data([0x03]), to: &payload)
        // The since-cursor tells servers which packets the filter covers;
        // without it they re-send their entire window every round.
        if let sinceTimestamp {
            var since = sinceTimestamp.bigEndian
            append(type: 0x05, value: withUnsafeBytes(of: &since) { Data($0) }, to: &payload)
        }
        return payload
    }

    func requests(_ type: MessageType) -> Bool {
        let bit: UInt64? = switch type {
        case .announce: 1 << 0
        case .message: 1 << 1
        case .fragment: 1 << 5
        case .fileTransfer: 1 << 7
        default: nil
        }
        guard let bit else { return false }
        return typeBits & bit != 0
    }

    private static func append(type: UInt8, value: Data, to payload: inout Data) {
        guard value.count <= Int(UInt16.max) else { return }
        payload.append(type)
        payload.append(UInt8((value.count >> 8) & 0xff))
        payload.append(UInt8(value.count & 0xff))
        payload.append(value)
    }

    private static func decodeFragmentIDs(_ data: Data) -> Set<Data>? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let ids = string.split(separator: ",").prefix(60).compactMap { token -> Data? in
            guard token.count == 16 else { return nil }
            return Data(hexString: String(token))
        }.filter { $0.count == 8 }
        return ids.isEmpty ? nil : Set(ids)
    }
}

final class WatchGossipStore {
    private struct StoredPacket {
        let id: Data
        let packet: BitchatPacket
    }

    private struct OrderedStore {
        var packets: [Data: BitchatPacket] = [:]
        var order: [Data] = []
        /// Logical start of `order`. Removing from an Array's front shifts
        /// every retained ID, which made sustained fragment traffic O(n) per
        /// eviction on the watch. Advance this cursor and compact only
        /// occasionally so eviction stays amortized O(1).
        var head = 0

        mutating func insert(_ packet: BitchatPacket, capacity: Int) {
            let id = WatchPacketID.compute(packet)
            if packets[id] != nil {
                packets[id] = packet
                return
            }
            packets[id] = packet
            order.append(id)
            while order.count - head > capacity {
                packets.removeValue(forKey: order[head])
                head += 1
            }
            if head >= 64, head * 2 >= order.count {
                order.removeFirst(head)
                head = 0
            }
        }

        func all() -> [StoredPacket] {
            guard head < order.count else { return [] }
            return order[head...].compactMap { id in
                packets[id].map { StoredPacket(id: id, packet: $0) }
            }
        }
    }

    private var announcements: [PeerID: StoredPacket] = [:]
    private var messages = OrderedStore()
    private var fragments = OrderedStore()
    private var files = OrderedStore()
    private let announcementCapacity = 128
    private let maximumAgeMilliseconds: UInt64 = 15 * 60 * 1_000

    func record(_ packet: BitchatPacket) {
        guard packet.recipientID == nil
                || packet.recipientID == WatchPacketFactory.broadcastRecipient,
              let type = MessageType(rawValue: packet.type) else { return }
        switch type {
        case .announce:
            announcements[PeerID(hexData: packet.senderID)] = StoredPacket(
                id: WatchPacketID.compute(packet),
                packet: packet
            )
            if announcements.count > announcementCapacity,
               let oldest = announcements.min(by: {
                   $0.value.packet.timestamp < $1.value.packet.timestamp
               })?.key {
                announcements.removeValue(forKey: oldest)
            }
        case .message:
            messages.insert(packet, capacity: 500)
        case .fragment:
            fragments.insert(packet, capacity: 600)
        case .fileTransfer:
            files.insert(packet, capacity: 100)
        default:
            break
        }
    }

    func publicPacketIDs(nowMilliseconds: UInt64) -> [Data] {
        publicSyncCandidates(nowMilliseconds: nowMilliseconds).map(\.packetID)
    }

    func publicSyncCandidates(nowMilliseconds: UInt64) -> [WatchSyncCandidate] {
        pruneStaleAnnouncements(nowMilliseconds: nowMilliseconds)
        let stored = Array(announcements.values) + messages.all()
        return stored
            .filter { isFresh($0.packet, now: nowMilliseconds) }
            .sorted { $0.packet.timestamp > $1.packet.timestamp }
            .map {
                WatchSyncCandidate(
                    packetID: $0.id,
                    timestamp: $0.packet.timestamp
                )
            }
    }

    func missingPackets(
        for request: WatchSyncRequest,
        nowMilliseconds: UInt64
    ) -> [BitchatPacket] {
        pruneStaleAnnouncements(nowMilliseconds: nowMilliseconds)
        let decoded = WatchGCS.decode(p: request.p, m: request.m, data: request.data)
        func requesterMightHave(_ stored: StoredPacket) -> Bool {
            let bucket = WatchGCS.bucket(
                stored.id,
                modulus: request.m
            )
            return decoded.binarySearch(bucket)
        }

        var candidates: [StoredPacket] = []
        if request.requests(.announce) {
            candidates.append(contentsOf: announcements.values)
        }
        if request.requests(.message) {
            candidates.append(contentsOf: messages.all().filter { stored in
                request.sinceTimestamp.map { stored.packet.timestamp >= $0 } ?? true
            })
        }
        if request.requests(.fragment) {
            candidates.append(contentsOf: fragments.all().filter { stored in
                let packet = stored.packet
                guard let filter = request.fragmentIDs else {
                    return request.sinceTimestamp.map { packet.timestamp >= $0 } ?? true
                }
                return packet.payload.count >= 8
                    && filter.contains(Data(packet.payload.prefix(8)))
            })
        }
        if request.requests(.fileTransfer) {
            candidates.append(contentsOf: files.all().filter { stored in
                request.sinceTimestamp.map { stored.packet.timestamp >= $0 } ?? true
            })
        }
        return candidates
            .filter { isFresh($0.packet, now: nowMilliseconds) }
            .filter { !requesterMightHave($0) }
            .prefix(128)
            .map { stored in
                var response = stored.packet
                response.ttl = 0
                response.isRSR = true
                return response
            }
    }

    private func isFresh(_ packet: BitchatPacket, now: UInt64) -> Bool {
        if packet.timestamp >= now {
            return packet.timestamp - now <= maximumAgeMilliseconds
        }
        return now - packet.timestamp <= maximumAgeMilliseconds
    }

    private func pruneStaleAnnouncements(nowMilliseconds: UInt64) {
        announcements = announcements.filter {
            isFresh($0.value.packet, now: nowMilliseconds)
        }
    }
}

private enum WatchPacketID {
    static func compute(_ packet: BitchatPacket) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data([packet.type]))
        hasher.update(data: packet.senderID)
        var timestamp = packet.timestamp.bigEndian
        withUnsafeBytes(of: &timestamp) { hasher.update(data: Data($0)) }
        hasher.update(data: packet.payload)
        return Data(hasher.finalize().prefix(16))
    }
}

private enum WatchGCS {
    struct Parameters {
        let p: Int
        let m: UInt32
        let data: Data
        let includedCount: Int
    }

    static func build(ids: [Data], maxBytes: Int, p: Int) -> Parameters {
        guard !ids.isEmpty else {
            return Parameters(p: p, m: 1, data: Data(), includedCount: 0)
        }
        // Encoding may retry with several candidate counts. Hash each packet
        // ID once; only the inexpensive modulus changes between attempts.
        let hashes = ids.map(hashValue)
        var count = min(ids.count, max(1, maxBytes * 8 / (p + 2)))
        while count > 0 {
            let m64 = min(UInt64(UInt32.max), UInt64(count) << UInt64(p))
            let m = UInt32(max(1, m64))
            let values = Array(Set(hashes.prefix(count).map {
                bucket($0, modulus: m)
            })).sorted()
            let encoded = encode(values, p: p)
            if encoded.count <= maxBytes {
                return Parameters(
                    p: p,
                    m: m,
                    data: encoded,
                    includedCount: count
                )
            }
            count = max(0, count * 9 / 10)
        }
        return Parameters(p: p, m: 1, data: Data(), includedCount: 0)
    }

    static func decode(p: Int, m: UInt32, data: Data) -> [UInt64] {
        guard (1...32).contains(p), m > 1 else { return [] }
        var reader = BitReader(data)
        var values: [UInt64] = []
        var accumulated: UInt64 = 0
        while let quotient = reader.readUnary(),
              let remainder = reader.readBits(p) {
            accumulated += (UInt64(quotient) << UInt64(p)) + remainder + 1
            guard accumulated < UInt64(m) else { break }
            values.append(accumulated)
        }
        return values
    }

    static func bucket(_ id: Data, modulus: UInt32) -> UInt64 {
        guard modulus > 1 else { return 0 }
        return bucket(hashValue(id), modulus: modulus)
    }

    private static func hashValue(_ id: Data) -> UInt64 {
        let digest = SHA256.hash(data: id)
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = (value << 8) | UInt64(byte) }
        return value & 0x7fff_ffff_ffff_ffff
    }

    private static func bucket(_ value: UInt64, modulus: UInt32) -> UInt64 {
        guard modulus > 1 else { return 0 }
        let mapped = value % UInt64(modulus)
        return mapped == 0 ? 1 : mapped
    }

    private static func encode(_ sorted: [UInt64], p: Int) -> Data {
        var writer = BitWriter()
        var previous: UInt64 = 0
        let mask = (UInt64(1) << UInt64(p)) - 1
        for value in sorted {
            let delta = value - previous
            previous = value
            let adjusted = delta - 1
            writer.writeOnes(Int(adjusted >> UInt64(p)))
            writer.writeBit(0)
            writer.writeBits(adjusted & mask, count: p)
        }
        return writer.data
    }

    private struct BitWriter {
        private var bytes = Data()
        private var current: UInt8 = 0
        private var count = 0
        var data: Data {
            mutating get {
                if count > 0 {
                    bytes.append(current << (8 - count))
                    current = 0
                    count = 0
                }
                return bytes
            }
        }
        mutating func writeBit(_ bit: UInt8) {
            current = (current << 1) | (bit & 1)
            count += 1
            if count == 8 {
                bytes.append(current)
                current = 0
                count = 0
            }
        }
        mutating func writeOnes(_ total: Int) {
            for _ in 0..<total { writeBit(1) }
        }
        mutating func writeBits(_ value: UInt64, count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                writeBit(UInt8((value >> UInt64(shift)) & 1))
            }
        }
    }

    private struct BitReader {
        let bytes: Data
        var bitIndex = 0
        init(_ bytes: Data) { self.bytes = bytes }
        mutating func readBit() -> UInt8? {
            guard bitIndex < bytes.count * 8 else { return nil }
            let byte = bytes[bitIndex / 8]
            let shift = 7 - (bitIndex % 8)
            bitIndex += 1
            return (byte >> shift) & 1
        }
        mutating func readUnary() -> Int? {
            var value = 0
            while let bit = readBit() {
                if bit == 0 { return value }
                value += 1
            }
            return nil
        }
        mutating func readBits(_ count: Int) -> UInt64? {
            var value: UInt64 = 0
            for _ in 0..<count {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | UInt64(bit)
            }
            return value
        }
    }
}

private extension Array where Element == UInt64 {
    func binarySearch(_ candidate: UInt64) -> Bool {
        var lower = 0
        var upper = count - 1
        while lower <= upper {
            let middle = (lower + upper) / 2
            if self[middle] == candidate { return true }
            if self[middle] < candidate {
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        return false
    }
}
