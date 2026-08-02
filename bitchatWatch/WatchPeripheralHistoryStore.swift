//
// WatchPeripheralHistoryStore.swift
// bitchat
//

import BitFoundation
import Foundation

/// Small, bounded transport history used only to make connection scheduling
/// fairer and more reliable. Peer identity is recorded only after a signed
/// direct ANNOUNCE; service data observed during scanning is never persisted as
/// trusted identity.
final class WatchPeripheralHistoryStore {
    struct Snapshot: Equatable {
        let peerID: String?
        let lastSuccessfulAt: Date?
        let lastAttemptAt: Date?
        let consecutiveFailures: Int
        let lastFailureAt: Date?
    }

    private struct Record: Codable {
        var peerID: String?
        var lastSuccessfulAt: Date?
        var lastAttemptAt: Date?
        var consecutiveFailures: Int = 0
        var lastFailureAt: Date?

        var mostRecentActivity: Date {
            max(
                lastSuccessfulAt ?? .distantPast,
                lastAttemptAt ?? .distantPast,
                lastFailureAt ?? .distantPast
            )
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumRecords = 256
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    private var records: [String: Record]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "watch_peripheral_history_v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        prune(now: Date())
    }

    func snapshot(for peripheralID: UUID) -> Snapshot {
        let record = records[peripheralID.uuidString]
        return Snapshot(
            peerID: record?.peerID,
            lastSuccessfulAt: record?.lastSuccessfulAt,
            lastAttemptAt: record?.lastAttemptAt,
            consecutiveFailures: record?.consecutiveFailures ?? 0,
            lastFailureAt: record?.lastFailureAt
        )
    }

    func recordAttempt(_ peripheralID: UUID, at date: Date = Date()) {
        var record = records[peripheralID.uuidString] ?? Record()
        record.lastAttemptAt = date
        records[peripheralID.uuidString] = record
        persist(now: date)
    }

    func recordSuccess(_ peripheralID: UUID, at date: Date = Date()) {
        var record = records[peripheralID.uuidString] ?? Record()
        record.lastSuccessfulAt = date
        record.consecutiveFailures = 0
        record.lastFailureAt = nil
        records[peripheralID.uuidString] = record
        persist(now: date)
    }

    func recordFailure(_ peripheralID: UUID, at date: Date = Date()) {
        var record = records[peripheralID.uuidString] ?? Record()
        record.consecutiveFailures += 1
        record.lastFailureAt = date
        records[peripheralID.uuidString] = record
        persist(now: date)
    }

    func recordAuthenticatedPeer(
        _ peerID: PeerID,
        for peripheralID: UUID,
        at date: Date = Date()
    ) {
        var record = records[peripheralID.uuidString] ?? Record()
        record.peerID = peerID.id
        record.lastSuccessfulAt = date
        records[peripheralID.uuidString] = record
        persist(now: date)
    }

    private func persist(now: Date) {
        prune(now: now)
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        records = records.filter { $0.value.mostRecentActivity >= cutoff }
        if records.count > maximumRecords {
            let keep = records
                .sorted { $0.value.mostRecentActivity > $1.value.mostRecentActivity }
                .prefix(maximumRecords)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
