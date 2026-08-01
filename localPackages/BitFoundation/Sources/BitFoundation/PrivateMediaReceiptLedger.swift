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
/// payload exists. Tombstones expire after the retry horizon. Corrupt or
/// unreadable state fails closed so a retry cannot double-deliver media.
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
    private let lock = NSLock()
    private var records: [String: Record]?

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        capacity: Int = 4_096,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
        self.now = now
    }

    public func state(for messageID: String) -> PrivateMediaReceiptLedgerState {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return .absent
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = loadIfNeeded(),
              let record = current[messageID] else {
            return records == nil ? .unavailable : .absent
        }

        switch record.kind {
        case .tombstone:
            guard !isExpired(record, at: now()) else {
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
        pruneExpiredTombstones(in: &current, at: now())

        if let existing = current[messageID] {
            guard existing.kind == .accepted,
                  existing.relativePath == relativePath else {
                return false
            }
            return true
        }
        guard !current.contains(where: {
            $0.key != messageID && $0.value.relativePath == relativePath
        }) else {
            return false
        }
        guard makeCapacityForInsert(in: &current) else { return false }

        current[messageID] = Record(
            kind: .accepted,
            relativePath: relativePath,
            recordedAt: now()
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
        pruneExpiredTombstones(in: &current, at: now())

        let acceptedURL = current[messageID]?.relativePath.flatMap(containedURL)
        if current[messageID] == nil,
           !makeCapacityForInsert(in: &current) {
            return false
        }
        current[messageID] = Record(
            kind: .tombstone,
            relativePath: nil,
            recordedAt: now()
        )
        guard persist(current) else { return false }
        records = current
        if let acceptedURL {
            try? fileManager.removeItem(at: acceptedURL)
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
                          && ((record.kind == .accepted && record.relativePath != nil)
                              || (record.kind == .tombstone && record.relativePath == nil))
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
        candidate = candidate.filter {
            $0.value.kind != .tombstone || !isExpired($0.value, at: date)
        }
    }

    private func isExpired(_ record: Record, at date: Date) -> Bool {
        date.timeIntervalSince(record.recordedAt) > ttl
    }

    private func makeCapacityForInsert(
        in candidate: inout [String: Record]
    ) -> Bool {
        guard candidate.count >= capacity else { return true }
        guard let victim = candidate
            .filter({ $0.value.kind == .tombstone })
            .min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key else {
            return false
        }
        candidate.removeValue(forKey: victim)
        return true
    }
}
