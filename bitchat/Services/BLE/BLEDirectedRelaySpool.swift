import BitFoundation
import Foundation

struct BLEDirectedRelaySpoolEntry {
    let recipient: PeerID
    let packet: BitchatPacket
    let timelyAlertEligible: Bool
}

/// Directed packets held at a relay while no onward link exists.
///
/// Bounded by count and by total payload bytes, evicting oldest-first: a
/// spooled noiseEncrypted packet keeps the framed-file decompression cap, so
/// a ~1 KB compressed frame can decode to ~1 MB, and a window-only bound let
/// a stream of such frames pin gigabytes before the first entry expired.
struct BLEDirectedRelaySpool {
    private struct Key: Hashable {
        let recipient: PeerID
        // periphery:ignore - read only via the synthesized Hashable
        // conformance (dictionary-key identity), which the indexer
        // cannot attribute.
        let messageID: String
    }

    private struct StoredPacket {
        let packet: BitchatPacket
        let enqueuedAt: Date
        let timelyAlertEligible: Bool
    }

    private let capacity: Int
    private let byteBudget: Int
    private var packets: [Key: StoredPacket] = [:]
    /// Enqueue order, oldest first: the eviction order, and the drain order.
    private var order: [Key] = []
    /// Sum of spooled payload sizes, maintained on every insert/remove.
    private var payloadBytes = 0

    init(
        capacity: Int = TransportConfig.bleDirectedSpoolCapacity,
        byteBudget: Int = TransportConfig.bleDirectedSpoolByteBudget
    ) {
        self.capacity = capacity
        self.byteBudget = byteBudget
    }

    var isEmpty: Bool {
        packets.isEmpty
    }

    var count: Int {
        packets.count
    }

    /// Spools `packet` unless it is already spooled for `recipient` or is
    /// larger than the whole byte budget, then evicts oldest-first until
    /// both the count and the byte budget hold.
    @discardableResult
    mutating func enqueue(
        packet: BitchatPacket,
        recipient: PeerID,
        messageID: String,
        enqueuedAt: Date,
        timelyAlertEligible: Bool = true
    ) -> Bool {
        let key = Key(recipient: recipient, messageID: messageID)
        guard packets[key] == nil, packet.payload.count <= byteBudget else {
            return false
        }

        packets[key] = StoredPacket(
            packet: packet,
            enqueuedAt: enqueuedAt,
            timelyAlertEligible: timelyAlertEligible
        )
        order.append(key)
        payloadBytes += packet.payload.count
        while order.count > capacity || payloadBytes > byteBudget {
            let victim = order.removeFirst()
            if let evicted = packets.removeValue(forKey: victim) {
                payloadBytes -= evicted.packet.payload.count
            }
        }
        return true
    }

    mutating func drainUnexpired(
        now: Date,
        window: TimeInterval,
        shouldDrain: (BLEDirectedRelaySpoolEntry) -> Bool = { _ in true }
    ) -> [BLEDirectedRelaySpoolEntry] {
        var entries: [BLEDirectedRelaySpoolEntry] = []
        entries.reserveCapacity(count)
        var retainedOrder: [Key] = []
        for key in order {
            guard let stored = packets[key] else { continue }
            if now.timeIntervalSince(stored.enqueuedAt) <= window {
                let entry = BLEDirectedRelaySpoolEntry(
                    recipient: key.recipient,
                    packet: stored.packet,
                    timelyAlertEligible: stored.timelyAlertEligible
                )
                if !shouldDrain(entry) {
                    retainedOrder.append(key)
                    continue
                }
                entries.append(entry)
            }
            packets.removeValue(forKey: key)
            payloadBytes -= stored.packet.payload.count
        }
        // Keep waiting packets in their original eviction order, with their
        // original expiry and byte accounting intact across maintenance retries.
        order = retainedOrder
        return entries
    }

    mutating func pruneExpired(now: Date, window: TimeInterval) {
        guard !packets.isEmpty else { return }

        var freshOrder: [Key] = []
        for key in order {
            guard let stored = packets[key] else { continue }
            if now.timeIntervalSince(stored.enqueuedAt) <= window {
                freshOrder.append(key)
            } else {
                packets.removeValue(forKey: key)
                payloadBytes -= stored.packet.payload.count
            }
        }
        order = freshOrder
    }

    mutating func removeAll() {
        packets.removeAll()
        order.removeAll()
        payloadBytes = 0
    }
}
