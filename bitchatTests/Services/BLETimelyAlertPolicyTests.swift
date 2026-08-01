import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE timely alert policy")
struct BLETimelyAlertPolicyTests {
    @Test("only message-capable transport classes enter the watch alert lane")
    func messageCapablePacketsOnly() {
        let allowed: [MessageType] = [.message, .noiseEncrypted]
        let blocked: [MessageType] = [
            .announce, .announceV2, .leave, .requestSync, .fragment,
            .fileTransfer, .courierEnvelope, .boardPost, .ping, .pong,
            .nostrCarrier, .prekeyBundle, .groupMessage, .voiceFrame,
            .noiseHandshake
        ]

        #expect(allowed.allSatisfy {
            BLEOutboundPacketPolicy.isTimelyAlertCandidate(packet(type: $0))
        })
        #expect(blocked.allSatisfy {
            !BLEOutboundPacketPolicy.isTimelyAlertCandidate(packet(type: $0))
        })
    }

    @Test("alert signals are compact and round-trip their message identity")
    func compactAlertSignal() throws {
        let source = packet(type: .noiseEncrypted)
        let data = BLETimelyAlertSignal.encode(for: source)
        let decoded = try #require(BLETimelyAlertSignal.decode(data))

        #expect(data.count == 14)
        #expect(decoded.type == source.type)
        #expect(decoded.timestamp == source.timestamp)
    }

    @Test("the alert lane omits BLE padding from encrypted direct messages")
    func unpaddedEncryptedAlert() {
        let source = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(repeating: 1, count: 8),
            recipientID: Data(repeating: 2, count: 8),
            timestamp: 1,
            payload: Data(repeating: 3, count: 48),
            signature: nil,
            ttl: 3
        )
        let encodedAlertData = BLEOutboundPacketPolicy.timelyAlertData(for: source)
        #expect(encodedAlertData != nil)
        let encodedRegularData = source.toBinaryData(padding: true)
        let encodedUnpaddedData = source.toBinaryData(padding: false)
        #expect(encodedRegularData != nil)
        #expect(encodedUnpaddedData != nil)
        guard let alertData = encodedAlertData,
              let regularData = encodedRegularData,
              let unpaddedData = encodedUnpaddedData else { return }

        #expect(alertData == unpaddedData)
        #expect(alertData.count < regularData.count)
    }

    private func packet(type: MessageType) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: Data(repeating: 1, count: 8),
            recipientID: nil,
            timestamp: 1,
            payload: Data(),
            signature: nil,
            ttl: 3
        )
    }
}
