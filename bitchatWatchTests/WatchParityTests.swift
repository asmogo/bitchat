import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("watchOS Android parity")
struct WatchParityTests {
    private final class MemoryPeerStateStore: WatchAuthenticatedPeerStateStore {
        var states: [String: WatchAuthenticatedPeerStatePacket] = [:]
        var pins: Set<String> = []

        func load(fingerprint: String) -> WatchAuthenticatedPeerStatePacket? {
            states[fingerprint]
        }

        func persist(
            fingerprint: String,
            state: WatchAuthenticatedPeerStatePacket
        ) -> Bool {
            states[fingerprint] = state
            if state.capabilities.contains(.privateMedia) {
                pins.insert(fingerprint)
            }
            return true
        }

        func isPrivateMediaPinned(fingerprint: String) -> Bool {
            pins.contains(fingerprint)
        }
    }

    @Test("favorite controls accept Android's canonical suffix")
    func favoriteControlCompatibility() {
        #expect(WatchFavoriteControl.parse("[FAVORITED]") == .favorited)
        #expect(WatchFavoriteControl.parse("[FAVORITED]:") == .favorited)
        #expect(WatchFavoriteControl.parse("[UNFAVORITED]:npub1abc") == .unfavorited)
        #expect(WatchFavoriteControl.parse("[FAVORITED]visible text") == nil)
    }

    @Test("watch packet freshness rejects timestamps outside the admission window")
    func packetFreshnessWindow() {
        let now: UInt64 = 2_000_000
        let window: UInt64 = 900
        let futureWindow: UInt64 = 600

        #expect(!WatchPacketFactory.isStale(
            timestampMilliseconds: now - window * 1_000,
            nowMilliseconds: now,
            maxAgeSeconds: window
        ))
        #expect(WatchPacketFactory.isStale(
            timestampMilliseconds: now - window * 1_000 - 1,
            nowMilliseconds: now,
            maxAgeSeconds: window
        ))
        #expect(!WatchPacketFactory.isStale(
            timestampMilliseconds: now + futureWindow * 1_000,
            nowMilliseconds: now,
            maxAgeSeconds: window,
            maxFutureSkewSeconds: futureWindow
        ))
        #expect(WatchPacketFactory.isStale(
            timestampMilliseconds: now + futureWindow * 1_000 + 1,
            nowMilliseconds: now,
            maxAgeSeconds: window,
            maxFutureSkewSeconds: futureWindow
        ))
    }

    @Test("public message admission matches Android fragment assembly ceiling")
    func publicMessageAdmissionLimit() {
        #expect(WatchBLEController.maxPublicContentBytes == 1_048_576)
        #expect(
            WatchBLEController.maxPublicContentBytes
                == FileTransferLimits.maxPayloadBytes
        )
        #expect(WatchBLEController.maxPrivateContentBytes == 255)
    }

    @Test("authenticated state belongs to one exact Noise generation")
    func generationBoundPeerState() {
        let store = MemoryPeerStateStore()
        let coordinator = WatchPeerSecurityCoordinator(store: store)
        let remoteStatic = Data((0..<32).map(UInt8.init))
        let peerID = PeerID(publicKey: remoteStatic)
        let first = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 1, count: 32)
        )
        let second = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 2, count: 32)
        )
        let state = WatchAuthenticatedPeerStatePacket(
            capabilities: [.privateMedia, .privateMediaReceipts],
            signingPublicKey: Data(repeating: 3, count: 32)
        )

        #expect(coordinator.begin(peerID: peerID, session: first) != nil)
        #expect(coordinator.status(peerID: peerID, session: first) == .awaiting)
        #expect(coordinator.receive(
            peerID: peerID,
            state: state,
            decryptedSession: first
        ).accepted)
        #expect(coordinator.status(peerID: peerID, session: first) == .proven(state))

        #expect(coordinator.begin(peerID: peerID, session: second) != nil)
        #expect(!coordinator.receive(
            peerID: peerID,
            state: state,
            decryptedSession: first
        ).accepted)
        #expect(coordinator.status(peerID: peerID, session: second) == .awaiting)
    }

    @Test("authenticated state permits persisted Ed25519 rotation")
    func authenticatedSigningKeyRotation() {
        let store = MemoryPeerStateStore()
        let coordinator = WatchPeerSecurityCoordinator(store: store)
        let remoteStatic = Data(repeating: 9, count: 32)
        let peerID = PeerID(publicKey: remoteStatic)
        let first = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 4, count: 32)
        )
        let second = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 5, count: 32)
        )
        let original = WatchAuthenticatedPeerStatePacket(
            capabilities: [.privateMedia],
            signingPublicKey: Data(repeating: 6, count: 32)
        )
        let rotated = WatchAuthenticatedPeerStatePacket(
            capabilities: [.privateMedia, .extendedFragmentSets],
            signingPublicKey: Data(repeating: 7, count: 32)
        )

        _ = coordinator.begin(peerID: peerID, session: first)
        #expect(coordinator.receive(
            peerID: peerID,
            state: original,
            decryptedSession: first
        ).accepted)
        #expect(!coordinator.permitsAnnouncementRelay(
            noisePublicKey: remoteStatic,
            announcedSigningKey: rotated.signingPublicKey,
            currentSigningKey: original.signingPublicKey
        ))
        _ = coordinator.begin(peerID: peerID, session: second)
        #expect(coordinator.receive(
            peerID: peerID,
            state: rotated,
            decryptedSession: second
        ).accepted)
        #expect(coordinator.persistedSigningKey(for: remoteStatic) == rotated.signingPublicKey)
        #expect(coordinator.permitsAnnouncementRelay(
            noisePublicKey: remoteStatic,
            announcedSigningKey: rotated.signingPublicKey,
            currentSigningKey: original.signingPublicKey
        ))
    }

    @Test("peer-state timeout never enables private media")
    func peerStateTimeoutBlocksMedia() {
        let coordinator = WatchPeerSecurityCoordinator(store: MemoryPeerStateStore())
        let remoteStatic = Data(repeating: 8, count: 32)
        let peerID = PeerID(publicKey: remoteStatic)
        let session = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 10, count: 32)
        )
        let nonce = coordinator.begin(peerID: peerID, session: session)
        #expect(nonce != nil)
        #expect(coordinator.expire(peerID: peerID, session: session, nonce: nonce!))
        #expect(coordinator.sendPolicy(
            peerID: peerID,
            authenticatedSession: session
        ) == .blocked)
    }

    @Test("GCS request omits packets the requester already has")
    func publicGossipMembership() {
        let store = WatchGossipStore()
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8),
            recipientID: nil,
            timestamp: WatchPacketFactory.nowMilliseconds(),
            payload: Data("hello".utf8),
            signature: Data(repeating: 2, count: 64),
            ttl: 7
        )
        store.record(packet)

        let empty = WatchSyncRequest.decode(
            WatchSyncRequest.publicPayload(packetIDs: [])
        )
        #expect(empty != nil)
        #expect(store.missingPackets(
            for: empty!,
            nowMilliseconds: WatchPacketFactory.nowMilliseconds()
        ).count == 1)

        let populated = WatchSyncRequest.decode(
            WatchSyncRequest.publicPayload(
                packetIDs: store.publicPacketIDs(
                    nowMilliseconds: WatchPacketFactory.nowMilliseconds()
                )
            )
        )
        #expect(populated != nil)
        #expect(store.missingPackets(
            for: populated!,
            nowMilliseconds: WatchPacketFactory.nowMilliseconds()
        ).isEmpty)
    }

    @Test("media retention evicts oldest references above the watch budget")
    func mediaRetentionBudget() {
        let base = URL(fileURLWithPath: "/tmp/watch-retention-tests")
        let candidates = [
            WatchMediaStore.RetentionCandidate(
                url: base.appendingPathComponent("old.m4a"),
                byteCount: 20 * 1_024 * 1_024,
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            WatchMediaStore.RetentionCandidate(
                url: base.appendingPathComponent("new.m4a"),
                byteCount: 20 * 1_024 * 1_024,
                timestamp: Date(timeIntervalSince1970: 2)
            )
        ]

        #expect(
            WatchMediaStore.retentionVictimURLs(from: candidates)
                == Set([candidates[0].url.standardizedFileURL])
        )
    }
}
