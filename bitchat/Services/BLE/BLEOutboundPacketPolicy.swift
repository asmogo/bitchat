import BitFoundation
import Foundation

enum BLEOutboundPacketPolicy {
    private static let fragmentPayloadHeaderSize = 13

    static func messageID(for packet: BitchatPacket) -> String {
        BLEIngressLinkRegistry.messageID(for: packet)
    }

    static func padsBLEFrame(for packetType: UInt8) -> Bool {
        switch MessageType(rawValue: packetType) {
        case .noiseEncrypted, .noiseHandshake:
            return true
        // voiceFrame is deliberately unpadded: padding to the 512 block would
        // push every ~490-byte signed voice packet over the MTU into the
        // fragment path.
        //
        // announceV2 is unpadded too, but for a different reason and it is worth
        // revisiting: it is ~75 bytes, so the smallest bucket would triple the
        // airtime of the most frequently sent packet in the protocol. Its length
        // is already near-constant by construction (the tag block is fixed
        // width); the residual variation is the capability width and whether a
        // bridge geohash is present. Making those fixed-width would be cheaper
        // than padding. See docs/PEER-ID-ROTATION.md.
        case .none, .announce, .announceV2, .message, .leave, .requestSync, .fragment, .fileTransfer, .courierEnvelope, .boardPost, .ping, .pong, .nostrCarrier, .prekeyBundle, .groupMessage, .voiceFrame:
            return false
        }
    }

    static func priority(for packet: BitchatPacket, data _: Data) -> BLEOutboundWritePriority {
        guard let messageType = MessageType(rawValue: packet.type) else { return .low }
        switch messageType {
        case .fragment:
            return .fragment(totalFragments: fragmentTotalCount(from: packet.payload))
        case .fileTransfer:
            return .fileTransfer
        case .announceV2:
            // Stated rather than inherited from `default`. Presence is small,
            // time-bounded to its epoch, and useless once stale, so it belongs
            // with the other control traffic at high priority — but that should
            // be a decision on the record, not a fall-through, since this type
            // is not emitted yet and nobody would notice the choice being made.
            return .high
        default:
            return .high
        }
    }

    /// Returns a fragment payload size that keeps the encoded outer fragment
    /// within the selected BLE link's limit. Account for routed v2 frames and
    /// the compression original-length field as well as the fixed envelope;
    /// otherwise a routed transfer can still exceed a watch-sized link after
    /// being "adapted" to it.
    static func fragmentChunkSize(
        forLinkLimit limit: Int,
        packet: BitchatPacket? = nil,
        hasDirectedRecipient: Bool = true
    ) -> Int {
        let route = packet?.route ?? []
        let version: UInt8 = route.isEmpty ? 1 : 2
        let headerSize = BinaryProtocol.headerSize(for: version)
            ?? BinaryProtocol.v1HeaderSize
        let recipientSize = hasDirectedRecipient ? BinaryProtocol.recipientIDSize : 0
        let routeSize = route.isEmpty ? 0 : 1 + route.count * BinaryProtocol.senderIDSize
        let compressionLengthReserve = version == 2 ? 4 : 2
        let overhead = headerSize
            + BinaryProtocol.senderIDSize
            + recipientSize
            + routeSize
            + fragmentPayloadHeaderSize
            + compressionLengthReserve
        return max(1, limit - overhead)
    }

    private static func fragmentTotalCount(from payload: Data) -> Int {
        guard payload.count >= 12 else { return Int(UInt16.max) }
        let totalHigh = Int(payload[10])
        let totalLow = Int(payload[11])
        let total = (totalHigh << 8) | totalLow
        return max(total, 1)
    }
}
