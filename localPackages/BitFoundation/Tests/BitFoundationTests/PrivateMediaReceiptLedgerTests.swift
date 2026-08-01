import Foundation
import Testing
@testable import BitFoundation

struct PrivateMediaReceiptLedgerTests {
    private let messageID = "media-00112233445566778899aabbccddeeff"

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
