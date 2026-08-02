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

    @Test("notification policy alerts unless the receiving conversation is visible")
    func notificationPolicy() {
        #expect(WatchNotifications.shouldScheduleAlert(
            isAppInForeground: false,
            isConversationActive: true
        ))
        #expect(WatchNotifications.shouldScheduleAlert(
            isAppInForeground: true,
            isConversationActive: false
        ))
        #expect(!WatchNotifications.shouldScheduleAlert(
            isAppInForeground: true,
            isConversationActive: true
        ))
    }

    @Test("notification identifiers are stable for system deduplication")
    func stableNotificationIdentifiers() {
        let first = WatchNotifications.directMessageDescriptor(
            messageID: "message-1",
            peerID: "peer-1",
            sender: "alice",
            preview: "hello"
        )
        let replay = WatchNotifications.directMessageDescriptor(
            messageID: "message-1",
            peerID: "peer-1",
            sender: "alice",
            preview: "hello"
        )
        let publicMessage = WatchNotifications.publicMessageDescriptor(
            messageID: "message-1",
            sender: "alice",
            preview: "hello"
        )

        #expect(first == replay)
        #expect(first.identifier == "dm-message-1")
        #expect(publicMessage.identifier == "public-message-1")
        #expect(first.identifier != publicMessage.identifier)
        #expect(
            WatchNotifications.catchUpDescriptor(signalID: "signal-1").identifier
                == "catchup-signal-1"
        )
    }

    @Test("compact phone alert signals decode without entering packet parsing")
    func timelyAlertSignalCompatibility() throws {
        var data = Data([
            0x62, 0x63, 0x68, 0x61, 0x01,
            MessageType.message.rawValue
        ])
        var timestamp = UInt64(42).bigEndian
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
        let signal = try #require(WatchTimelyAlertSignal.decode(data))

        #expect(signal.type == MessageType.message.rawValue)
        #expect(signal.timestamp == 42)
    }

    @Test("known peer identities survive suspension without becoming active links")
    func knownPeerPersistence() throws {
        let suite = "watch-known-peer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = Data((0..<32).map(UInt8.init))
        let peerID = PeerID(publicKey: key)
        let signingKey = Data(repeating: 7, count: 32)
        let peer = WatchPeer(
            peerID: peerID,
            nickname: "alice",
            noisePublicKey: key,
            signingPublicKey: signingKey,
            lastSeen: Date(),
            capabilities: [.privateMedia]
        )

        WatchKnownPeerStore(defaults: defaults, storageKey: "peers").remember(peer)
        let restored = WatchKnownPeerStore(
            defaults: defaults,
            storageKey: "peers"
        ).peer(peerID)

        #expect(restored?.nickname == "alice")
        #expect(restored?.signingPublicKey == signingKey)
        #expect(restored?.capabilities == [.privateMedia])
    }

    @Test("watch mesh keeps discovery armed until Android-compatible link capacity")
    func persistentDiscoveryCapacity() {
        #expect(WatchMeshRuntimePolicy.maximumPhysicalLinks == 8)
        #expect(WatchMeshRuntimePolicy.maximumBackgroundConnections == 2)
        #expect(WatchMeshRuntimePolicy.shouldKeepDiscoveryArmed(
            physicalLinks: 0
        ))
        #expect(WatchMeshRuntimePolicy.shouldKeepDiscoveryArmed(
            physicalLinks: 7
        ))
        #expect(!WatchMeshRuntimePolicy.shouldKeepDiscoveryArmed(
            physicalLinks: 8
        ))
        #expect(WatchMeshRuntimePolicy.shouldRunDiscovery(
            isAppInForeground: true,
            physicalLinks: 0
        ))
        #expect(!WatchMeshRuntimePolicy.shouldRunDiscovery(
            isAppInForeground: false,
            physicalLinks: 0
        ))
        #expect(WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 1,
            pendingAttempts: 2
        ))
        #expect(!WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 1,
            pendingAttempts: 3
        ))
        #expect(!WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 8,
            pendingAttempts: 0
        ))
        #expect(!WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 7,
            pendingAttempts: 1
        ))
        #expect(WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 1,
            pendingAttempts: 0,
            isAppInForeground: false
        ))
        #expect(!WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: 2,
            pendingAttempts: 0,
            isAppInForeground: false
        ))
    }

    @Test("background relay selection honors the two-link system limit and diversity")
    func backgroundRelaySelection() {
        let now = Date()
        let duplicateStrong = WatchBackgroundRelayCandidate(
            id: UUID(), peerID: "peer-a", supportsAlertLane: true,
            rssi: -20, connectedAt: now
        )
        let duplicateWeak = WatchBackgroundRelayCandidate(
            id: UUID(), peerID: "peer-a", supportsAlertLane: true,
            rssi: -30, connectedAt: now.addingTimeInterval(-30)
        )
        let distinct = WatchBackgroundRelayCandidate(
            id: UUID(), peerID: "peer-b", supportsAlertLane: true,
            rssi: -60, connectedAt: now.addingTimeInterval(-60)
        )
        let legacy = WatchBackgroundRelayCandidate(
            id: UUID(), peerID: "peer-c", supportsAlertLane: false,
            rssi: -10, connectedAt: now.addingTimeInterval(-90)
        )
        let selected = WatchMeshRuntimePolicy.selectBackgroundRelays([
            legacy, duplicateWeak, distinct, duplicateStrong
        ])

        #expect(selected.map(\.id) == [duplicateStrong.id, distinct.id])
    }

    @Test("connection phases have bounded Android-style recovery deadlines")
    func boundedConnectionPhases() {
        #expect(WatchConnectionPhase.connecting.timeout == 30)
        #expect(WatchConnectionPhase.services.timeout == 15)
        #expect(WatchConnectionPhase.characteristics.timeout == 15)
        #expect(WatchConnectionPhase.subscribing.timeout == 15)
    }

    @Test("candidate ranking prefers diversity, success, fairness, then RSSI")
    func connectionCandidateRanking() {
        let now = Date()
        let duplicate = WatchDiscoveryCandidateScore(
            id: UUID(),
            advertisedPeerIsConnected: true,
            previouslySuccessful: true,
            lastAttempt: nil,
            rssi: -20,
            discoveredAt: now
        )
        let reliable = WatchDiscoveryCandidateScore(
            id: UUID(),
            advertisedPeerIsConnected: false,
            previouslySuccessful: true,
            lastAttempt: now.addingTimeInterval(-60),
            rssi: -70,
            discoveredAt: now
        )
        let strongNew = WatchDiscoveryCandidateScore(
            id: UUID(),
            advertisedPeerIsConnected: false,
            previouslySuccessful: false,
            lastAttempt: nil,
            rssi: -30,
            discoveredAt: now
        )
        let ranked = WatchMeshRuntimePolicy.rankCandidates([
            duplicate,
            strongNew,
            reliable
        ])

        #expect(ranked.map(\.id) == [reliable.id, strongNew.id, duplicate.id])
    }

    @Test("peripheral history persists only authenticated identity mappings")
    func peripheralHistoryPersistence() throws {
        let suite = "watch-peripheral-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peripheralID = UUID()
        let peerID = PeerID(publicKey: Data(repeating: 9, count: 32))
        let successfulAt = Date()
        let attemptedAt = successfulAt.addingTimeInterval(-100)
        let store = WatchPeripheralHistoryStore(defaults: defaults, storageKey: "history")

        store.recordAttempt(peripheralID, at: attemptedAt)
        #expect(store.snapshot(for: peripheralID).peerID == nil)
        store.recordAuthenticatedPeer(peerID, for: peripheralID, at: successfulAt)

        let restored = WatchPeripheralHistoryStore(
            defaults: defaults,
            storageKey: "history"
        ).snapshot(for: peripheralID)
        #expect(restored.peerID == peerID.id)
        #expect(restored.lastAttemptAt == attemptedAt)
        #expect(restored.lastSuccessfulAt == successfulAt)
    }

    @Test("legacy links without an alert lane keep their background wake path")
    func legacyBackgroundLanePolicy() {
        #expect(WatchMeshRuntimePolicy.shouldQuietMeshLaneInBackground(
            hasAlertLane: true
        ))
        #expect(!WatchMeshRuntimePolicy.shouldQuietMeshLaneInBackground(
            hasAlertLane: false
        ))
    }

    @Test("unreachable candidates cool down instead of starving connection slots")
    func connectionFailureBackoff() {
        #expect(WatchMeshRuntimePolicy.connectionRetryCooldown(
            consecutiveFailures: 0
        ) == 0)
        #expect(WatchMeshRuntimePolicy.connectionRetryCooldown(
            consecutiveFailures: 1
        ) == 0)
        #expect(WatchMeshRuntimePolicy.connectionRetryCooldown(
            consecutiveFailures: 2
        ) == 30)
        #expect(WatchMeshRuntimePolicy.connectionRetryCooldown(
            consecutiveFailures: 3
        ) == 60)
        #expect(WatchMeshRuntimePolicy.connectionRetryCooldown(
            consecutiveFailures: 20
        ) == 600)
        #expect(WatchMeshRuntimePolicy.minimumCandidateRSSI == -90)
    }

    @Test("conflicting duplicate fragments overwrite instead of destroying the stream")
    func fragmentAssemblerDuplicateOverwrite() throws {
        func fragmentPacket(index: Int, total: Int, chunk: Data) -> BitchatPacket {
            var payload = Data(repeating: 0x2A, count: 8)
            var bigIndex = UInt16(index).bigEndian
            var bigTotal = UInt16(total).bigEndian
            withUnsafeBytes(of: &bigIndex) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &bigTotal) { payload.append(contentsOf: $0) }
            payload.append(MessageType.fileTransfer.rawValue)
            payload.append(chunk)
            return BitchatPacket(
                type: MessageType.fragment.rawValue,
                senderID: Data(repeating: 1, count: 8),
                recipientID: nil,
                timestamp: 1,
                payload: payload,
                signature: nil,
                ttl: 7
            )
        }

        let assembler = WatchFragmentAssembler()
        _ = assembler.append(try #require(
            WatchFragmentHeader(packet: fragmentPacket(index: 0, total: 2, chunk: Data([1, 2, 3])))
        ))
        _ = assembler.append(try #require(
            WatchFragmentHeader(packet: fragmentPacket(index: 0, total: 2, chunk: Data([4, 5])))
        ))
        let result = assembler.append(try #require(
            WatchFragmentHeader(packet: fragmentPacket(index: 1, total: 2, chunk: Data([6])))
        ))

        guard case let .complete(data) = result else {
            Issue.record("expected completion after duplicate overwrite")
            return
        }
        #expect(data == Data([4, 5, 6]))
    }

    @Test("peripheral history backs off failures and resets on success")
    func peripheralHistoryFailureTracking() throws {
        let suite = "watch-peripheral-failure-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peripheralID = UUID()
        let store = WatchPeripheralHistoryStore(defaults: defaults, storageKey: "history")
        let failedAt = Date()

        store.recordFailure(peripheralID, at: failedAt)
        store.recordFailure(peripheralID, at: failedAt)
        var snapshot = WatchPeripheralHistoryStore(
            defaults: defaults,
            storageKey: "history"
        ).snapshot(for: peripheralID)
        #expect(snapshot.consecutiveFailures == 2)
        #expect(snapshot.lastFailureAt == failedAt)

        store.recordSuccess(peripheralID, at: failedAt.addingTimeInterval(30))
        snapshot = store.snapshot(for: peripheralID)
        #expect(snapshot.consecutiveFailures == 0)
        #expect(snapshot.lastFailureAt == nil)
    }

    @Test("background reconnect is immediate and does not expire silent peers")
    func persistentBackgroundTopology() {
        #expect(WatchMeshRuntimePolicy.reconnectDelay(
            isAppInForeground: false,
            attempt: 5
        ) == 0)
        #expect(WatchMeshRuntimePolicy.reconnectDelay(
            isAppInForeground: true,
            attempt: 1
        ) == 1)
        #expect(WatchMeshRuntimePolicy.reconnectDelay(
            isAppInForeground: true,
            attempt: 20
        ) == 16)
        #expect(!WatchMeshRuntimePolicy.shouldExpirePeerPresence(
            isAppInForeground: false
        ))
        #expect(WatchMeshRuntimePolicy.shouldExpirePeerPresence(
            isAppInForeground: true
        ))
    }

    @Test("Bluetooth alert gate releases when visible alert work completes")
    func bluetoothAlertGateSignal() async {
        let gate = WatchBluetoothAlertGate()
        let ticket = gate.arm()
        let waiter = Task {
            await gate.wait(ticket, timeoutNanoseconds: 2_000_000_000)
        }

        gate.signal()
        await waiter.value
        #expect(gate.pendingCount == 0)
    }

    @Test("Bluetooth alert gate remembers completion before async wait starts")
    func bluetoothAlertGateEarlySignal() async {
        let gate = WatchBluetoothAlertGate()
        let ticket = gate.arm()
        gate.signal()

        await gate.wait(ticket, timeoutNanoseconds: 2_000_000_000)
        #expect(gate.pendingCount == 0)
    }

    @Test("Bluetooth alert gate has a bounded timeout")
    func bluetoothAlertGateTimeout() async {
        let gate = WatchBluetoothAlertGate()
        let ticket = gate.arm()
        await gate.wait(ticket, timeoutNanoseconds: 1_000_000)
        #expect(gate.pendingCount == 0)
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

    @Test("peer-state timeout falls back to legacy media unless pinned")
    func peerStateTimeoutMediaPolicy() {
        let store = MemoryPeerStateStore()
        let coordinator = WatchPeerSecurityCoordinator(store: store)
        let remoteStatic = Data(repeating: 8, count: 32)
        let peerID = PeerID(publicKey: remoteStatic)
        let session = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 10, count: 32)
        )
        let nonce = coordinator.begin(peerID: peerID, session: session)
        #expect(nonce != nil)
        #expect(coordinator.expire(peerID: peerID, session: session, nonce: nonce!))

        // A peer that never proved media capability (current Android) gets
        // iOS's signed legacy directed fallback instead of a permanent block.
        #expect(coordinator.sendPolicy(
            peerID: peerID,
            authenticatedSession: session
        ) == .legacyFallback)

        // Once the peer did prove private media, the sticky pin makes a later
        // timeout a downgrade attempt: stay blocked, never fall back to clear.
        store.pins.insert(WatchPeerSecurityCoordinator.fingerprint(remoteStatic))
        #expect(coordinator.sendPolicy(
            peerID: peerID,
            authenticatedSession: session
        ) == .blocked)
    }

    @Test("proven peer without media capability falls back unless pinned")
    func provenNoMediaPolicy() {
        let store = MemoryPeerStateStore()
        let coordinator = WatchPeerSecurityCoordinator(store: store)
        let remoteStatic = Data(repeating: 3, count: 32)
        let peerID = PeerID(publicKey: remoteStatic)
        let session = WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: Data(repeating: 11, count: 32)
        )
        _ = coordinator.begin(peerID: peerID, session: session)
        #expect(coordinator.receive(
            peerID: peerID,
            state: WatchAuthenticatedPeerStatePacket(
                capabilities: [],
                signingPublicKey: Data(repeating: 6, count: 32)
            ),
            decryptedSession: session
        ).accepted)
        #expect(coordinator.sendPolicy(
            peerID: peerID,
            authenticatedSession: session
        ) == .legacyFallback)
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
