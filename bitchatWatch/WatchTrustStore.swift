//
// WatchTrustStore.swift
// bitchat
//

import Foundation

struct WatchPeerTrust: Codable, Equatable {
    var isFavorite = false
    var theyFavoritedUs = false
    var verifiedFingerprint: String?

    var isVerified: Bool { verifiedFingerprint != nil }
}

final class WatchTrustStore {
    static let shared = WatchTrustStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "watch_peer_trust_v1"
    private var records: [String: WatchPeerTrust]

    private init() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: WatchPeerTrust].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func trust(for peerID: String, fingerprint: String?) -> WatchPeerTrust {
        var trust = records[peerID] ?? WatchPeerTrust()
        if let verified = trust.verifiedFingerprint,
           verified.caseInsensitiveCompare(fingerprint ?? "") != .orderedSame {
            trust.verifiedFingerprint = nil
            records[peerID] = trust
            persist()
        }
        return trust
    }

    @discardableResult
    func toggleFavorite(peerID: String) -> WatchPeerTrust {
        var trust = records[peerID] ?? WatchPeerTrust()
        trust.isFavorite.toggle()
        records[peerID] = trust
        persist()
        return trust
    }

    @discardableResult
    func setTheyFavoritedUs(_ value: Bool, peerID: String) -> WatchPeerTrust {
        var trust = records[peerID] ?? WatchPeerTrust()
        trust.theyFavoritedUs = value
        records[peerID] = trust
        persist()
        return trust
    }

    @discardableResult
    func setVerified(
        _ verified: Bool,
        peerID: String,
        fingerprint: String?
    ) -> WatchPeerTrust {
        var trust = records[peerID] ?? WatchPeerTrust()
        trust.verifiedFingerprint = verified ? fingerprint : nil
        records[peerID] = trust
        persist()
        return trust
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
