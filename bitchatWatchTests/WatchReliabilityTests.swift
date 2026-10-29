import BitFoundation
import CryptoKit
import Foundation
import Security
import Testing
@testable import bitchat

@Suite("watchOS reliability regressions")
struct WatchReliabilityTests {

    @Test("identity read failures never overwrite a stored key")
    func identityReadErrorsDoNotCreateKeys() {
        let failures: [KeychainReadResult] = [
            .deviceLocked, .authenticationFailed, .accessDenied,
            .otherError(errSecNotAvailable), .success(Data([0]))
        ]
        for failure in failures {
            var created = false
            var persisted = false
            let result = WatchIdentity.loadOrCreateKey(
                read: failure,
                create: { created = true; return Data(repeating: 1, count: 32) },
                isValid: { $0.count == 32 },
                persist: { _ in persisted = true; return errSecSuccess }
            )
            #expect(!result.isPersistent)
            #expect(!created && !persisted)
        }
    }

    @Test("identity creation requires a missing key and successful persistence")
    func identityCreationAndReuse() {
        let key = Data(repeating: 1, count: 32)
        var writes: [Data] = []
        let created = WatchIdentity.loadOrCreateKey(
            read: .itemNotFound, create: { key }, isValid: { $0.count == 32 },
            persist: { writes.append($0); return errSecSuccess }
        )
        #expect(created.isPersistent && created.data == key)
        #expect(writes == [key])
        let reused = WatchIdentity.loadOrCreateKey(
            read: .success(key), create: { Data() }, isValid: { $0.count == 32 },
            persist: { writes.append($0); return errSecSuccess }
        )
        #expect(reused.isPersistent && reused.data == key)
        #expect(writes == [key])
        let rejected = WatchIdentity.loadOrCreateKey(
            read: .itemNotFound, create: { key }, isValid: { $0.count == 32 },
            persist: { _ in errSecInteractionNotAllowed }
        )
        #expect(!rejected.isPersistent)
    }

    @Test("late delivery receipts and send callbacks cannot undo confirmed delivery")
    func deliveryStatusDoesNotRegress() {
        var message = WatchChatMessage(
            id: "message", sender: "me", senderPeerID: nil,
            content: "hello", timestamp: Date(), isSelf: true,
            isPrivate: true, conversationPeerID: nil,
            status: "sending", media: nil
        )
        let failed = message.updateDeliveryStatus("failed")
        let delivered = message.updateDeliveryStatus("delivered")
        let lateSend = message.updateDeliveryStatus("sent")
        let lateFailure = message.updateDeliveryStatus("failed")
        let read = message.updateDeliveryStatus("read")
        let lateReceipt = message.updateDeliveryStatus("delivered")
        #expect(failed && delivered && read)
        #expect(!lateSend && !lateFailure && !lateReceipt)
        #expect(message.status == "read")
    }

    @Test("conversation archives recover attachments after their container moves")
    func conversationRestoresMediaPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = WatchMediaAttachment(
            url: URL(fileURLWithPath: "/old-container/Documents/ReceivedMedia/voice.aac"),
            fileName: "voice.aac", mimeType: "audio/aac", byteCount: 12,
            isLive: true
        )
        let message = WatchChatMessage(
            id: "message", sender: "alice", senderPeerID: nil,
            content: "voice.aac", timestamp: Date(), isSelf: false,
            isPrivate: true, conversationPeerID: nil,
            status: "", media: attachment
        )
        let fileURL = root.appendingPathComponent("conversation.json")
        WatchConversationStore(fileURL: fileURL).flush(WatchConversationSnapshot(
            messages: [message], privateMessages: ["peer": [message]], unreadDms: ["peer": 1]
        ))
        let restored = WatchConversationStore(fileURL: fileURL).load()
        let documents = try #require(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first)
        let expectedURL = documents.appendingPathComponent("ReceivedMedia/voice.aac")
        #expect(restored.messages.first?.media?.url == expectedURL)
        #expect(restored.privateMessages["peer"]?.first?.media?.url == expectedURL)
        #expect(restored.messages.first?.media?.isLive == false)
        #expect(restored.unreadDms["peer"] == 1)
    }

    @Test("received Unicode filenames fit the filesystem, including name collisions")
    func unicodeMediaFilenameFitsByteLimit() throws {
        let packet = WatchFilePacket(
            fileName: UUID().uuidString + String(repeating: "🙂", count: 100) + ".bin",
            fileSize: 3, mimeType: "application/octet-stream", content: Data([1, 2, 3])
        )
        let first = try #require(WatchMediaStore.save(packet))
        defer { WatchMediaStore.remove(first) }
        let second = try #require(WatchMediaStore.save(packet))
        defer { WatchMediaStore.remove(second) }
        #expect(first.url != second.url)
        #expect(first.fileName.utf8.count <= 255)
        #expect(second.fileName.utf8.count <= 255)
        #expect(try Data(contentsOf: second.url) == packet.content)
    }

    @Test("replacement Noise handshake receives old packets and defers new packets")
    func noiseReplacementReceivesInFlightMessages() throws {
        let identity = WatchIdentity.shared
        let manager = WatchNoiseManager(identity: identity)
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = PeerID(publicKey: remoteKey.publicKey.rawRepresentation)
        let original = NoiseSession(
            peerID: identity.peerID,
            role: .initiator,
            keychain: identity,
            localStaticKey: remoteKey
        )
        let replacement = NoiseSession(
            peerID: identity.peerID,
            role: .initiator,
            keychain: identity,
            localStaticKey: remoteKey
        )
        defer {
            manager.clearAll()
            original.reset()
            replacement.reset()
        }

        let first = try manager.process(original.startHandshake(), from: peerID)
        let reply = try #require(first.response)
        let finish = try #require(try original.processHandshakeMessage(reply))
        #expect(try manager.process(finish, from: peerID).established)
        let oldSession = try #require(manager.authenticatedSession(for: peerID))
        let oldCiphertext = try original.encrypt(Data("in flight".utf8))

        let next = try manager.process(replacement.startHandshake(), from: peerID)
        let received = try #require(try manager.decryptWithSession(oldCiphertext, from: peerID))
        #expect(received.plaintext == Data("in flight".utf8))
        #expect(received.session == oldSession)
        #expect(!manager.isEstablished(with: peerID))

        let nextReply = try #require(next.response)
        let nextFinish = try #require(try replacement.processHandshakeMessage(nextReply))
        let earlyCiphertext = try replacement.encrypt(Data("new generation".utf8))
        #expect(try manager.decryptWithSession(earlyCiphertext, from: peerID) == nil)
        #expect(try manager.process(nextFinish, from: peerID).established)
        let deferred = try #require(try manager.decryptWithSession(earlyCiphertext, from: peerID))
        #expect(deferred.plaintext == Data("new generation".utf8))
        #expect(deferred.session != oldSession)
    }

    @Test("active extended fragment transfers survive housekeeping and complete in order")
    func fragmentProgressKeepsExtendedTransferAlive() throws {
        let assembler = WatchFragmentAssembler()
        let start = Date(timeIntervalSince1970: 1_000)
        let count = 2_000
        for index in 0..<count {
            let now = start.addingTimeInterval(Double(index) * 0.025)
            assembler.expire(now: now)
            let header = try fragmentHeader(index: index, total: count)
            let result = assembler.append(header, now: now)
            if index == count - 1 {
                guard case let .complete(data) = result else {
                    Issue.record("active transfer was expired before completion")
                    return
                }
                #expect(data == Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }))
                #expect(!assembler.hasActiveAssemblies)
            }
        }
    }

    @Test("duplicate fragments do not extend an abandoned transfer's lifetime")
    func duplicateFragmentsDoNotRefreshExpiry() throws {
        let assembler = WatchFragmentAssembler()
        let start = Date(timeIntervalSince1970: 1_000)
        let header = try fragmentHeader(index: 0, total: 2)
        _ = assembler.append(header, now: start)
        _ = assembler.append(header, now: start.addingTimeInterval(29))
        assembler.expire(now: start.addingTimeInterval(30))
        #expect(!assembler.hasActiveAssemblies)
    }

    @Test("rejected fragments release their memory without evicting healthy transfers")
    func rejectedAssemblyReleasesMemoryBudget() throws {
        let assembler = WatchFragmentAssembler()
        let content = Data(repeating: 7, count: FileTransferLimits.maxPayloadBytes)
        for id in UInt8(1)...UInt8(4) {
            _ = assembler.append(try fragmentHeader(
                index: 0, total: 2, id: id, chunk: content
            ))
        }
        let rejected = assembler.append(try fragmentHeader(index: 0, total: 3, id: 1))
        guard case .rejected = rejected else {
            Issue.record("inconsistent metadata must discard its assembly")
            return
        }
        _ = assembler.append(try fragmentHeader(index: 0, total: 2, id: 5, chunk: content))
        for id in UInt8(2)...UInt8(5) {
            let result = assembler.append(try fragmentHeader(index: 1, total: 2, id: id))
            guard case let .complete(data) = result else {
                Issue.record("healthy transfer was evicted after another assembly was rejected")
                return
            }
            #expect(data.count == content.count + 1)
            #expect(data.first == 7 && data.last == 1)
        }
        #expect(!assembler.hasActiveAssemblies)
    }

    private func fragmentHeader(
        index: Int,
        total: Int,
        id: UInt8 = 0x2A,
        chunk: Data? = nil
    ) throws -> WatchFragmentHeader {
        var payload = Data(repeating: id, count: 8)
        payload.append(contentsOf: [
            UInt8(index >> 8), UInt8(truncatingIfNeeded: index),
            UInt8(total >> 8), UInt8(truncatingIfNeeded: total),
            MessageType.fileTransfer.rawValue
        ])
        payload.append(chunk ?? Data([UInt8(truncatingIfNeeded: index)]))
        return try #require(WatchFragmentHeader(packet: BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: Data(repeating: 1, count: 8),
            recipientID: nil,
            timestamp: 1,
            payload: payload,
            signature: nil,
            ttl: 7
        )))
    }
}
