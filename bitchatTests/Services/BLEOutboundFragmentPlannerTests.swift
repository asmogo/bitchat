import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE outbound fragment planner tests")
struct BLEOutboundFragmentPlannerTests {
    @Test("planner splits packets and preserves reassembled payload")
    func plannerSplitsAndReassemblesPacket() throws {
        let packet = makePacket(payload: makePayload(count: 384))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: 128,
            directedPeer: nil,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xA1, count: 8)
        ))
        let headers = try plan.fragmentPackets.map { try #require(BLEFragmentHeader(packet: $0)) }
        let reassembled = headers.reduce(into: Data()) { data, header in
            data.append(header.fragmentData)
        }
        let decoded = try #require(BinaryProtocol.decode(reassembled))

        #expect(plan.fragmentVersion == 1)
        #expect(plan.chunkSize == 128)
        #expect(plan.spacingMs == TransportConfig.bleFragmentSpacingMs)
        #expect(headers.map(\.index) == Array(0..<headers.count))
        #expect(decoded.type == packet.type)
        #expect(decoded.payload == packet.payload)
        #expect(plan.fragmentPackets.allSatisfy { $0.recipientID == nil })
    }

    @Test("directed fragments target the directed peer and use directed pacing")
    func directedFragmentsUseDirectedRecipientAndSpacing() throws {
        let directedPeer = PeerID(str: "8877665544332211")
        let packet = makePacket(payload: makePayload(count: 256))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: 96,
            directedPeer: directedPeer,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xB2, count: 8)
        ))

        #expect(plan.spacingMs == TransportConfig.bleFragmentSpacingDirectedMs)
        #expect(plan.fragmentPackets.allSatisfy { $0.recipientID == Data(hexString: directedPeer.id) })
    }

    @Test("watch-sized private media fragments fit the negotiated notification limit")
    func privateMediaFragmentsRespectWatchLinkLimit() throws {
        let directedPeer = PeerID(str: "8877665544332211")
        let notificationLimit = 185
        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: "0011223344556677") ?? Data(),
            recipientID: Data(hexString: directedPeer.id),
            timestamp: 0x0102030405,
            payload: makePayload(count: 45_000),
            signature: nil,
            ttl: 3,
            version: 1
        )
        let maxChunk = BLEOutboundPacketPolicy.fragmentChunkSize(
            forLinkLimit: notificationLimit,
            packet: packet,
            hasDirectedRecipient: true
        )
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: true,
            maxChunk: maxChunk,
            directedPeer: directedPeer,
            transferId: "watch-image"
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xE5, count: 8)
        ))
        let encodedFragments = try plan.fragmentPackets.map {
            try #require($0.toBinaryData(padding: false))
        }
        let headers = try plan.fragmentPackets.map {
            try #require(BLEFragmentHeader(packet: $0))
        }
        let reassembled = headers.reduce(into: Data()) { data, header in
            data.append(header.fragmentData)
        }
        let decoded = try #require(BinaryProtocol.decode(reassembled))

        #expect(plan.chunkSize == maxChunk)
        #expect(encodedFragments.allSatisfy { $0.count <= notificationLimit })
        #expect(decoded.type == packet.type)
        #expect(decoded.payload == packet.payload)
    }

    @Test("route-aware fragments use version two and route-sized chunking")
    func routeAwareFragmentsUseVersionTwoAndRouteSizedChunking() throws {
        let route = [
            Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]),
            Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27])
        ]
        let packet = makePacket(payload: makePayload(count: 192), route: route, isRSR: true)
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 128,
            fragmentID: Data(repeating: 0xC3, count: 8)
        ))
        let firstHeader = try #require(BLEFragmentHeader(packet: plan.fragmentPackets[0]))

        #expect(plan.fragmentVersion == 2)
        #expect(plan.chunkSize == 50)
        #expect(firstHeader.fragmentData.count <= 50)
        #expect(plan.fragmentPackets.allSatisfy { $0.route == route && $0.isRSR })
    }

    @Test("routed fragments fit a watch-sized negotiated link")
    func routedFragmentsRespectNegotiatedLinkLimit() throws {
        let linkLimit = 185
        let recipient = PeerID(str: "8877665544332211")
        let route = [
            Data(hexString: "1020304050607080") ?? Data(),
            Data(hexString: "90a0b0c0d0e0f001") ?? Data()
        ]
        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: "0011223344556677") ?? Data(),
            recipientID: Data(hexString: recipient.id),
            timestamp: 0x0102030405,
            payload: makePayload(count: 8_000),
            signature: nil,
            ttl: 3,
            version: 2,
            route: route
        )
        let maxChunk = BLEOutboundPacketPolicy.fragmentChunkSize(
            forLinkLimit: linkLimit,
            packet: packet,
            hasDirectedRecipient: true
        )
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: true,
            maxChunk: maxChunk,
            directedPeer: recipient,
            transferId: "routed-watch-image"
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xF6, count: 8)
        ))
        let encoded = try plan.fragmentPackets.map {
            try #require($0.toBinaryData(padding: false))
        }

        #expect(plan.fragmentVersion == 2)
        #expect(plan.fragmentPackets.allSatisfy { $0.route == route })
        #expect(encoded.allSatisfy { $0.count <= linkLimit })
    }

    @Test("fragment sizing honors constrained links below the old 64-byte floor")
    func constrainedLinkCanUseSmallChunks() throws {
        let linkLimit = 48
        let packet = makePacket(payload: makePayload(count: 128))
        let maxChunk = BLEOutboundPacketPolicy.fragmentChunkSize(
            forLinkLimit: linkLimit,
            packet: packet,
            hasDirectedRecipient: false
        )
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: maxChunk,
            directedPeer: nil,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0x17, count: 8)
        ))
        let encoded = try plan.fragmentPackets.map {
            try #require($0.toBinaryData(padding: false))
        }

        #expect(plan.chunkSize == maxChunk)
        #expect(plan.chunkSize < 64)
        #expect(encoded.allSatisfy { $0.count <= linkLimit })
    }

    @Test("planner rejects fragment counts above the receiver protocol limit")
    func excessiveFragmentCountReturnsNil() {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: "0011223344556677") ?? Data(),
            recipientID: nil,
            timestamp: 0x0102030405,
            payload: makePayload(count: 10_500),
            signature: nil,
            ttl: 3,
            version: 2
        )
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: 1,
            directedPeer: nil,
            transferId: nil
        )

        #expect(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0x4A, count: 8)
        ) == nil)
    }

    @Test("invalid fragment IDs do not produce a plan")
    func invalidFragmentIDReturnsNil() {
        let packet = makePacket(payload: makePayload(count: 128))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: nil
        )

        #expect(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0x00, count: 7)
        ) == nil)
    }

    @Test("private media v1 accepts exactly 256 fragments and rejects 257")
    func privateMediaCrossPlatformFragmentBoundary() throws {
        let maxPayload = makePayload(count: 160 * 1024, seed: 0xFACE_CAFE)

        func plan(payloadCount: Int) throws -> BLEOutboundFragmentPlan {
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: "0011223344556677") ?? Data(),
                recipientID: Data(hexString: "8877665544332211"),
                timestamp: 0x0102030405,
                payload: Data(maxPayload.prefix(payloadCount)),
                signature: nil,
                ttl: 3,
                version: 2
            )
            return try #require(BLEOutboundFragmentPlanner.makePlan(
                for: BLEOutboundFragmentTransferRequest(
                    packet: packet,
                    pad: false,
                    maxChunk: nil,
                    directedPeer: PeerID(str: "8877665544332211"),
                    transferId: "boundary"
                ),
                defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
                bleMaxMTU: 512,
                fragmentID: Data(repeating: 0xD4, count: 8)
            ))
        }

        func firstPlan(withAtLeast target: Int) throws -> BLEOutboundFragmentPlan {
            var low = 1
            var high = maxPayload.count
            while low < high {
                let mid = low + (high - low) / 2
                if try plan(payloadCount: mid).totalFragments >= target {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            return try plan(payloadCount: low)
        }

        let at256 = try firstPlan(withAtLeast: 256)
        let at257 = try firstPlan(withAtLeast: 257)

        #expect(at256.totalFragments == 256)
        #expect(BLEOutboundFragmentPlanner.isPrivateMediaV1Compatible(at256))
        #expect(at257.totalFragments == 257)
        #expect(!BLEOutboundFragmentPlanner.isPrivateMediaV1Compatible(at257))
    }

    private func makePacket(
        payload: Data,
        route: [Data]? = nil,
        isRSR: Bool = false
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            recipientID: nil,
            timestamp: 0x0102030405,
            payload: payload,
            signature: nil,
            ttl: 3,
            route: route,
            isRSR: isRSR
        )
    }

    private func makePayload(count: Int, seed: UInt64 = 0xABCD_1234) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }
}
