//
// WatchKnownPeerStore.swift
// bitchat
//

import BitFoundation
import Foundation

/// Durable public identity metadata for peers whose signed packets have
/// already been admitted. Active-neighbour state remains ephemeral; this
/// store exists so a suspended or relaunched watch can authenticate and show
/// the message that caused a Bluetooth background wake before a fresh announce
/// has time to arrive.
final class WatchKnownPeerStore {
    private struct Record: Codable {
        let peerID: PeerID
        let nickname: String
        let noisePublicKey: Data
        let signingPublicKey: Data
        let lastSeen: Date
        let capabilities: UInt64
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumPeers = 128
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    /// Announces refresh much more often than durable identity recovery needs.
    /// Coalescing unchanged last-seen updates avoids encoding the whole peer
    /// map and writing UserDefaults every time each neighbor heartbeats.
    private let lastSeenPersistenceInterval: TimeInterval = 5 * 60
    private var records: [String: Record]
    private var persistedAtByPeer: [String: Date]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "watch_known_peers_v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        persistedAtByPeer = records.mapValues(\.lastSeen)
        prune(now: Date())
    }

    func peer(_ peerID: PeerID) -> WatchPeer? {
        guard let record = records[peerID.id],
              record.peerID == peerID,
              record.noisePublicKey.count == 32,
              PeerID(publicKey: record.noisePublicKey) == peerID,
              record.signingPublicKey.count == 32 else { return nil }
        return WatchPeer(
            peerID: peerID,
            nickname: record.nickname,
            noisePublicKey: record.noisePublicKey,
            signingPublicKey: record.signingPublicKey,
            lastSeen: record.lastSeen,
            capabilities: PeerCapabilities(rawValue: record.capabilities)
        )
    }

    func remember(_ peer: WatchPeer) {
        guard peer.noisePublicKey.count == 32,
              PeerID(publicKey: peer.noisePublicKey) == peer.peerID,
              peer.signingPublicKey.count == 32 else { return }
        let peerKey = peer.peerID.id
        let nickname = String(
            peer.nickname.precomposedStringWithCanonicalMapping.prefix(32)
        )
        let previous = records[peerKey]
        let updatedLastSeen = max(previous?.lastSeen ?? .distantPast, peer.lastSeen)
        let identityChanged = previous == nil
            || previous?.nickname != nickname
            || previous?.noisePublicKey != peer.noisePublicKey
            || previous?.signingPublicKey != peer.signingPublicKey
            || previous?.capabilities != peer.capabilities.rawValue
        let lastPersistedAt = persistedAtByPeer[peerKey] ?? .distantPast
        let lastSeenPersistenceDue = updatedLastSeen.timeIntervalSince(
            lastPersistedAt
        ) >= lastSeenPersistenceInterval

        records[peerKey] = Record(
            peerID: peer.peerID,
            nickname: nickname,
            noisePublicKey: peer.noisePublicKey,
            signingPublicKey: peer.signingPublicKey,
            lastSeen: updatedLastSeen,
            capabilities: peer.capabilities.rawValue
        )
        prune(now: updatedLastSeen)
        guard identityChanged || lastSeenPersistenceDue else { return }
        if persist() {
            persistedAtByPeer[peerKey] = updatedLastSeen
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        records = records.filter { $0.value.lastSeen >= cutoff }
        if records.count > maximumPeers {
            let keep = records.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(maximumPeers)
            records = Dictionary(uniqueKeysWithValues: keep.map {
                ($0.peerID.id, $0)
            })
        }
        persistedAtByPeer = persistedAtByPeer.filter {
            records[$0.key] != nil
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}
