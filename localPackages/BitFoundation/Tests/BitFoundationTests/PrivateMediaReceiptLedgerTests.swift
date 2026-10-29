import Foundation
import Testing
@testable import BitFoundation

struct PrivateMediaReceiptLedgerTests {
    private let messageID = "media-00112233445566778899aabbccddeeff"
    private let secondMessageID = "media-ffeeddccbbaa99887766554433221100"
    private let thirdMessageID = "media-0123456789abcdef0123456789abcdef"

    private struct TestError: Error {}

    @Test
    func acceptedDecisionPersistsAndMissingPayloadBecomesRetryable() throws {
        let root = makeRoot("accepted")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)

        let first = PrivateMediaReceiptLedger(baseDirectory: root)
        #expect(first.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(first.state(for: messageID) == .accepted(payload))

        let relaunched = PrivateMediaReceiptLedger(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .accepted(payload))
        try FileManager.default.removeItem(at: payload)
        #expect(relaunched.state(for: messageID) == .absent)
    }

    @Test
    func tombstonePersistsAndPreventsResurrection() throws {
        let root = makeRoot("tombstone")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let store = PrivateMediaReceiptLedger(baseDirectory: root)

        #expect(store.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(store.recordDeleted(messageID: messageID))
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(
            PrivateMediaReceiptLedger(baseDirectory: root).state(for: messageID)
                == .tombstoned
        )

        let retry = try makePayload(in: root)
        #expect(!store.commitAccepted(messageID: messageID, storedURL: retry))
    }

    @Test
    func failedPayloadRemovalIsDurablyRetriedAfterRelaunch() throws {
        let root = makeRoot("unlink-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let seed = PrivateMediaReceiptLedger(baseDirectory: root)
        #expect(seed.commitAccepted(messageID: messageID, storedURL: payload))

        let unlinkFailure = PrivateMediaReceiptLedger(
            baseDirectory: root,
            payloadRemover: { _ in throw TestError() }
        )
        #expect(unlinkFailure.recordDeleted(messageID: messageID))
        #expect(FileManager.default.fileExists(atPath: payload.path))

        // A new instance can only discover the orphaned payload through the
        // durable path retained by the tombstone.
        let relaunched = PrivateMediaReceiptLedger(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(
            PrivateMediaReceiptLedger(baseDirectory: root).state(for: messageID)
                == .tombstoned
        )
    }

    @Test
    func recordKindsHaveIndependentCapacityAndRefuseUnsafeReplacement() throws {
        let root = makeRoot("independent-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root)
        let secondPayload = try makePayload(in: root)
        let thirdPayload = try makePayload(in: root)
        let date = Date(timeIntervalSince1970: 1_000)
        let store = PrivateMediaReceiptLedger(
            baseDirectory: root,
            capacity: 1,
            ttl: 100,
            now: { date }
        )

        #expect(store.commitAccepted(
            messageID: messageID,
            storedURL: firstPayload
        ))
        #expect(store.recordDeleted(messageID: messageID))

        // The accepted slot is independent of the tombstone slot. Admitting
        // this payload must not discard the still-live deletion decision.
        #expect(store.commitAccepted(
            messageID: secondMessageID,
            storedURL: secondPayload
        ))
        #expect(store.state(for: messageID) == .tombstoned)
        #expect(store.state(for: secondMessageID) == .accepted(secondPayload))

        // Once either kind's own slot is full, refuse instead of evicting a
        // durable accepted owner or an unexpired tombstone.
        #expect(!store.commitAccepted(
            messageID: thirdMessageID,
            storedURL: thirdPayload
        ))
        #expect(!store.recordDeleted(messageID: secondMessageID))
        #expect(store.state(for: messageID) == .tombstoned)
        #expect(store.state(for: secondMessageID) == .accepted(secondPayload))
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
    }

    @Test
    func missingPayloadsReleaseCapacityWithoutReplayingTheirIDs() throws {
        let root = makeRoot("missing-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root)
        let nextPayload = try makePayload(in: root)
        let store = PrivateMediaReceiptLedger(baseDirectory: root, capacity: 1)

        #expect(store.recordDeleted(messageID: thirdMessageID))
        #expect(store.commitAccepted(messageID: messageID, storedURL: firstPayload))
        try FileManager.default.removeItem(at: firstPayload)
        #expect(store.commitAccepted(messageID: secondMessageID, storedURL: nextPayload))

        let restored = PrivateMediaReceiptLedger(baseDirectory: root, capacity: 1)
        #expect(restored.state(for: messageID) == .absent)
        #expect(restored.state(for: secondMessageID) == .accepted(nextPayload))
        #expect(restored.state(for: thirdMessageID) == .tombstoned)
    }

    @Test
    func idempotentAcceptedCommitSkipsLedgerWideMaintenance() throws {
        let root = makeRoot("idempotent-fast-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        var clockReads = 0
        let store = PrivateMediaReceiptLedger(
            baseDirectory: root,
            now: {
                clockReads += 1
                return Date(timeIntervalSince1970: 1_000)
            }
        )
        #expect(store.commitAccepted(messageID: messageID, storedURL: payload))

        clockReads = 0
        #expect(store.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(clockReads == 0)
    }

    @Test
    func corruptLedgerFailsClosed() throws {
        let root = makeRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(".private-media-receipts-v1.json")
        )
        let payload = try makePayload(in: root)
        let store = PrivateMediaReceiptLedger(baseDirectory: root)

        #expect(store.state(for: messageID) == .unavailable)
        #expect(!store.commitAccepted(messageID: messageID, storedURL: payload))
    }

    @Test
    func payloadMustBeInsideLedgerRoot() throws {
        let root = makeRoot("root")
        let outside = makeRoot("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let payload = try makePayload(in: outside)

        #expect(!PrivateMediaReceiptLedger(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
    }

    private func makeRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "private-media-ledger-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makePayload(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let payload = root.appendingPathComponent("img_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: payload)
        return payload
    }
}
