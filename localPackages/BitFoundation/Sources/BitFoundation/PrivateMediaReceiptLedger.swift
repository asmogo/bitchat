import Foundation

public enum PrivateMediaReceiptLedgerState: Equatable {
    case absent
    case accepted(URL)
    case tombstoned
    case unavailable
}

/// A bounded durable receiver decision for stable private-media IDs.
///
/// Accepted records retain a relative payload path and remain live while that
/// payload exists. Tombstones and accepted records have independent bounds so
/// accepted traffic cannot evict explicit deletion intent. A tombstone retains
/// its payload path until unlink succeeds, then expires after the retry horizon.
/// Corrupt or unreadable state fails closed so a retry cannot double-deliver
/// media.
public final class PrivateMediaReceiptLedger: @unchecked Sendable {
    private static let currentVersion = 1
    private static let fileName = ".private-media-receipts-v1.json"

    private struct Record: Codable, Equatable {
        enum Kind: String, Codable {
            case accepted
            case tombstone
        }

        let kind: Kind
        let relativePath: String?
        let recordedAt: Date
    }

    private struct Snapshot: Codable {
        let version: Int
        let records: [String: Record]
    }

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private let payloadRemover: (URL) throws -> Void
    private let lock = NSLock()
    private var records: [String: Record]?

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        capacity: Int = 4_096,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init,
        payloadRemover: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
        self.now = now
        self.payloadRemover = payloadRemover ?? {
            try fileManager.removeItem(at: $0)
        }
    }

    public func state(for messageID: String) -> PrivateMediaReceiptLedgerState {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return .absent
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = loadIfNeeded(),
              var record = current[messageID] else {
            return records == nil ? .unavailable : .absent
        }

        switch record.kind {
        case .tombstone:
            if record.relativePath != nil {
                _ = retryPendingPayloadRemoval(
                    messageID: messageID,
                    in: &current
                )
                record = current[messageID] ?? record
            }
            // Never age out deletion intent while its payload path still
            // needs cleanup; doing so would leave an untracked orphan.
            guard record.relativePath != nil || !isExpired(record, at: now()) else {
                current.removeValue(forKey: messageID)
                guard persist(current) else { return .tombstoned }
                records = current
                return .absent
            }
            return .tombstoned

        case .accepted:
            guard let relativePath = record.relativePath,
                  let payloadURL = containedURL(for: relativePath) else {
                return .unavailable
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: payloadURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                current.removeValue(forKey: messageID)
                guard persist(current) else { return .unavailable }
                records = current
                return .absent
            }
            return .accepted(payloadURL)
        }
    }

    /// Commits only after the payload exists. A caller must remove the payload
    /// and withhold delivery/ACK when this returns false.
    @discardableResult
    public func commitAccepted(messageID: String, storedURL: URL) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID),
              let relativePath = relativePath(for: storedURL) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: storedURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = loadIfNeeded() else { return false }

        // Conversation restoration replays every live attachment through this
        // method. Resolve the common idempotent case before the ledger-wide
        // expiry scan so migration stays O(messages), not O(messages*ledger).
        if let existing = current[messageID],
           existing.kind == .accepted {
            return existing.relativePath == relativePath
        }
        let date = now()
        pruneExpiredTombstones(in: &current, at: date)

        guard current[messageID] == nil else { return false }
        guard !current.contains(where: {
            $0.key != messageID && $0.value.relativePath == relativePath
        }) else {
            return false
        }
        if !hasCapacity(
            for: .accepted,
            replacing: messageID,
            in: current
        ) {
            // Retention can unlink attachments after their conversation rows
            // have been trimmed. Reclaim those missing payloads at capacity;
            // waiting for a replay of each old ID eventually blocks all new
            // private media. Keep live owners and deletion decisions intact.
            let missing = current.compactMap { id, record -> String? in
                guard record.kind == .accepted,
                      let path = record.relativePath,
                      let url = containedURL(for: path),
                      !fileManager.fileExists(atPath: url.path) else { return nil }
                return id
            }
            for id in missing { current.removeValue(forKey: id) }
            guard hasCapacity(
                for: .accepted,
                replacing: messageID,
                in: current
            ) else { return false }
        }

        current[messageID] = Record(
            kind: .accepted,
            relativePath: relativePath,
            recordedAt: date
        )
        guard persist(current) else { return false }
        records = current
        return true
    }

    /// Records deletion before unlinking so retries cannot resurrect media.
    @discardableResult
    public func recordDeleted(messageID: String) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = loadIfNeeded() else { return false }
        let date = now()
        pruneExpiredTombstones(in: &current, at: date)

        guard hasCapacity(
            for: .tombstone,
            replacing: messageID,
            in: current
        ) else { return false }

        // This path is the durable unlink journal. Re-recording a pending
        // tombstone must retain it rather than turning a failed unlink into an
        // untracked payload.
        let pendingRelativePath = current[messageID]?.relativePath
        current[messageID] = Record(
            kind: .tombstone,
            relativePath: pendingRelativePath,
            recordedAt: date
        )
        guard persist(current) else { return false }
        records = current
        if pendingRelativePath != nil {
            _ = retryPendingPayloadRemoval(
                messageID: messageID,
                in: &current
            )
        }
        return true
    }

    private func loadIfNeeded() -> [String: Record]? {
        if let records { return records }
        guard let fileURL = ledgerURL else { return nil }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            records = [:]
            return records
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == Self.currentVersion,
                  snapshot.records.allSatisfy({ messageID, record in
                      PrivateMediaMessageIdentity.isStableID(messageID)
                          && isStructurallyValid(record)
                  }) else {
                return nil
            }
            records = snapshot.records
            return records
        } catch {
            return nil
        }
    }

    private func persist(_ candidate: [String: Record]) -> Bool {
        guard let baseDirectory, let fileURL = ledgerURL else { return false }
        do {
            try fileManager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
            let snapshot = Snapshot(
                version: Self.currentVersion,
                records: candidate
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
            return true
        } catch {
            return false
        }
    }

    private var ledgerURL: URL? {
        baseDirectory?.appendingPathComponent(Self.fileName)
    }

    private func relativePath(for url: URL) -> String? {
        guard let baseDirectory else { return nil }
        let base = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        let relative = String(candidate.path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    private func containedURL(for relativePath: String) -> URL? {
        guard let baseDirectory,
              !(relativePath as NSString).isAbsolutePath else {
            return nil
        }
        let base = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }

    private func pruneExpiredTombstones(
        in candidate: inout [String: Record],
        at date: Date
    ) {
        // Collect only the keys that will be removed instead of allocating a
        // replacement dictionary for every insertion.
        let expiredMessageIDs = candidate.compactMap { messageID, record in
            record.kind == .tombstone
                && record.relativePath == nil
                && isExpired(record, at: date)
                ? messageID
                : nil
        }
        for messageID in expiredMessageIDs {
            candidate.removeValue(forKey: messageID)
        }
    }

    private func isExpired(_ record: Record, at date: Date) -> Bool {
        date.timeIntervalSince(record.recordedAt) > ttl
    }

    private func hasCapacity(
        for kind: Record.Kind,
        replacing messageID: String,
        in candidate: [String: Record]
    ) -> Bool {
        guard candidate[messageID]?.kind != kind else { return true }
        var matchingCount = 0
        for record in candidate.values where record.kind == kind {
            matchingCount += 1
            if matchingCount >= capacity { return false }
        }
        return true
    }

    private func isStructurallyValid(_ record: Record) -> Bool {
        switch record.kind {
        case .accepted:
            guard let relativePath = record.relativePath else { return false }
            return containedURL(for: relativePath) != nil
        case .tombstone:
            guard let relativePath = record.relativePath else { return true }
            return containedURL(for: relativePath) != nil
        }
    }

    /// Retries a pathful tombstone and retires its payload path only after the
    /// unlink is verified. A failure leaves both the durable and cached record
    /// pathful so a later lookup or relaunch can retry safely.
    @discardableResult
    private func retryPendingPayloadRemoval(
        messageID: String,
        in candidate: inout [String: Record]
    ) -> Bool {
        guard let record = candidate[messageID],
              record.kind == .tombstone,
              let relativePath = record.relativePath,
              let payloadURL = containedURL(for: relativePath) else {
            return true
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: payloadURL.path,
            isDirectory: &isDirectory
        ) {
            // FileManager.removeItem recursively deletes directories. A
            // corrupt ledger must never turn this cleanup into a tree removal.
            guard !isDirectory.boolValue else { return false }
            do {
                try payloadRemover(payloadURL)
            } catch {
                return false
            }
            guard !fileManager.fileExists(atPath: payloadURL.path) else {
                return false
            }
        }

        let completedRecord = Record(
            kind: .tombstone,
            relativePath: nil,
            recordedAt: record.recordedAt
        )
        candidate[messageID] = completedRecord
        guard persist(candidate) else {
            candidate[messageID] = record
            return false
        }
        records = candidate
        return true
    }
}
