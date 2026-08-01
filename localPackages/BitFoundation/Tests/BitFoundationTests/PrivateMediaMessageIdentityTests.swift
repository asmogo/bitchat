import Foundation
import Testing
@testable import BitFoundation

struct PrivateMediaMessageIdentityTests {
    private let sender = PeerID(str: "0011223344556677")
    private let recipient = PeerID(str: "8899aabbccddeeff")
    private let fileName = "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"

    @Test
    func versionOneGoldenVectorIsStable() {
        #expect(
            PrivateMediaMessageIdentity.stableID(
                senderPeerID: sender,
                recipientPeerID: recipient,
                fileName: fileName
            ) == "media-910bd42c65060ab76bb6406f220c4516"
        )
    }

    @Test
    func receiptsRequireBothPrivateMediaCapabilities() {
        #expect(
            PrivateMediaReceiptPolicy.stableMessageID(
                peerCapabilities: [.privateMedia],
                senderPeerID: sender,
                recipientPeerID: recipient,
                fileName: fileName
            ) == nil
        )
        #expect(
            PrivateMediaReceiptPolicy.stableMessageID(
                peerCapabilities: [.privateMediaReceipts],
                senderPeerID: sender,
                recipientPeerID: recipient,
                fileName: fileName
            ) == nil
        )
        #expect(
            PrivateMediaReceiptPolicy.stableMessageID(
                peerCapabilities: [.privateMedia, .privateMediaReceipts],
                senderPeerID: sender,
                recipientPeerID: recipient,
                fileName: fileName
            ) == "media-910bd42c65060ab76bb6406f220c4516"
        )
    }

    @Test
    func aliasesAndEligibleVoiceNamesConverge() throws {
        let senderKey = Data(repeating: 0x11, count: 32)
        let recipientKey = Data(repeating: 0x22, count: 32)
        let voiceName = "voice_0011223344556677.m4a"
        let senderID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: PeerID(hexData: senderKey),
            recipientPeerID: PeerID(publicKey: recipientKey),
            fileName: voiceName
        ))
        let receiverID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: PeerID(publicKey: senderKey),
            recipientPeerID: PeerID(hexData: recipientKey),
            fileName: voiceName
        ))

        #expect(senderID == receiverID)
        #expect(PrivateMediaMessageIdentity.isStableID(senderID))
        #expect(PrivateMediaMessageIdentity.stableID(
            senderPeerID: sender,
            recipientPeerID: recipient,
            fileName: "voice_1234.m4a"
        ) == nil)
    }
}
