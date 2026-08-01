//
// WatchPeerSecurity.swift
// bitchat
//

import BitFoundation
import CryptoKit
import Foundation

enum WatchFavoriteControl: Equatable {
    case favorited
    case unfavorited

    static func parse(_ content: String) -> WatchFavoriteControl? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, value) in [
            ("[FAVORITED]", WatchFavoriteControl.favorited),
            ("[UNFAVORITED]", WatchFavoriteControl.unfavorited)
        ] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let suffix = trimmed.dropFirst(prefix.count)
            guard suffix.isEmpty || suffix.first == ":" else { return nil }
            return value
        }
        return nil
    }
}

protocol WatchAuthenticatedPeerStateStore {
    func load(fingerprint: String) -> WatchAuthenticatedPeerStatePacket?
    func persist(
        fingerprint: String,
        state: WatchAuthenticatedPeerStatePacket
    ) -> Bool
    func isPrivateMediaPinned(fingerprint: String) -> Bool
}

final class WatchKeychainPeerStateStore: WatchAuthenticatedPeerStateStore {
    private struct Record: Codable {
        let capabilities: UInt64
        let signingPublicKey: Data
        let privateMediaPinned: Bool
    }

    private let keychain: KeychainManagerProtocol
    private let accountPrefix = "watch_authenticated_peer_state_v1_"

    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }

    func load(fingerprint: String) -> WatchAuthenticatedPeerStatePacket? {
        guard case let .success(data) = keychain.getIdentityKeyWithResult(
            forKey: accountPrefix + fingerprint.lowercased()
        ), let record = try? JSONDecoder().decode(Record.self, from: data),
           record.signingPublicKey.count == 32 else {
            return nil
        }
        return WatchAuthenticatedPeerStatePacket(
            capabilities: PeerCapabilities(rawValue: record.capabilities),
            signingPublicKey: record.signingPublicKey
        )
    }

    func persist(
        fingerprint: String,
        state: WatchAuthenticatedPeerStatePacket
    ) -> Bool {
        let pinned = isPrivateMediaPinned(fingerprint: fingerprint)
            || state.capabilities.contains(.privateMedia)
        let record = Record(
            capabilities: state.capabilities.rawValue,
            signingPublicKey: state.signingPublicKey,
            privateMediaPinned: pinned
        )
        guard let data = try? JSONEncoder().encode(record) else { return false }
        if case .success = keychain.saveIdentityKeyWithResult(
            data,
            forKey: accountPrefix + fingerprint.lowercased()
        ) {
            return true
        }
        return false
    }

    func isPrivateMediaPinned(fingerprint: String) -> Bool {
        guard case let .success(data) = keychain.getIdentityKeyWithResult(
            forKey: accountPrefix + fingerprint.lowercased()
        ), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return false
        }
        return record.privateMediaPinned
    }
}

enum WatchAuthenticatedPeerStateStatus: Equatable {
    case missing
    case awaiting
    case timedOut
    case proven(WatchAuthenticatedPeerStatePacket)
}

enum WatchPrivateMediaPolicy: Equatable {
    case needsHandshake
    case awaitingPeerState
    case encrypted(
        session: WatchAuthenticatedNoiseSession,
        supportsReceipts: Bool,
        supportsExtendedFragmentSets: Bool
    )
    case blocked
}

struct WatchAuthenticatedPeerStateReceipt {
    let accepted: Bool
    let shouldEcho: Bool
}

/// Owns application authentication above Noise. Every proof is scoped to the
/// remote static key and handshake hash of the exact transport generation,
/// persisted before its signing key or capabilities can be published.
final class WatchPeerSecurityCoordinator {
    private struct SessionState {
        let session: WatchAuthenticatedNoiseSession
        let fingerprint: String
        var status: WatchAuthenticatedPeerStateStatus
        var echoSent: Bool
        let timeoutNonce: UUID
    }

    private let store: WatchAuthenticatedPeerStateStore
    private var sessions: [PeerID: SessionState] = [:]

    init(store: WatchAuthenticatedPeerStateStore) {
        self.store = store
    }

    @discardableResult
    func begin(
        peerID: PeerID,
        session: WatchAuthenticatedNoiseSession
    ) -> UUID? {
        guard valid(session, for: peerID) else { return nil }
        if sessions[peerID]?.session == session {
            return nil
        }
        let nonce = UUID()
        sessions[peerID] = SessionState(
            session: session,
            fingerprint: Self.fingerprint(session.remoteStaticKey),
            status: .awaiting,
            echoSent: false,
            timeoutNonce: nonce
        )
        return nonce
    }

    func expire(
        peerID: PeerID,
        session: WatchAuthenticatedNoiseSession,
        nonce: UUID
    ) -> Bool {
        guard var current = sessions[peerID],
              current.session == session,
              current.timeoutNonce == nonce,
              current.status == .awaiting else {
            return false
        }
        current.status = .timedOut
        sessions[peerID] = current
        return true
    }

    func receive(
        peerID: PeerID,
        state: WatchAuthenticatedPeerStatePacket,
        decryptedSession: WatchAuthenticatedNoiseSession
    ) -> WatchAuthenticatedPeerStateReceipt {
        guard valid(decryptedSession, for: peerID),
              var current = sessions[peerID],
              current.session == decryptedSession else {
            return WatchAuthenticatedPeerStateReceipt(
                accepted: false,
                shouldEcho: false
            )
        }
        if case let .proven(existing) = current.status {
            return WatchAuthenticatedPeerStateReceipt(
                accepted: existing == state,
                shouldEcho: false
            )
        }
        guard store.persist(fingerprint: current.fingerprint, state: state) else {
            return WatchAuthenticatedPeerStateReceipt(
                accepted: false,
                shouldEcho: false
            )
        }
        let shouldEcho = !current.echoSent
        current.echoSent = true
        current.status = .proven(state)
        sessions[peerID] = current
        return WatchAuthenticatedPeerStateReceipt(
            accepted: true,
            shouldEcho: shouldEcho
        )
    }

    func status(
        peerID: PeerID,
        session: WatchAuthenticatedNoiseSession
    ) -> WatchAuthenticatedPeerStateStatus {
        guard sessions[peerID]?.session == session else { return .missing }
        return sessions[peerID]?.status ?? .missing
    }

    func provenState(
        peerID: PeerID,
        session: WatchAuthenticatedNoiseSession
    ) -> WatchAuthenticatedPeerStatePacket? {
        guard case let .proven(state) = status(peerID: peerID, session: session) else {
            return nil
        }
        return state
    }

    func sendPolicy(
        peerID: PeerID,
        authenticatedSession: WatchAuthenticatedNoiseSession?
    ) -> WatchPrivateMediaPolicy {
        guard let authenticatedSession,
              valid(authenticatedSession, for: peerID) else {
            return .needsHandshake
        }
        switch status(peerID: peerID, session: authenticatedSession) {
        case .awaiting, .missing:
            return .awaitingPeerState
        case let .proven(state):
            if state.capabilities.contains(.privateMedia) {
                return .encrypted(
                    session: authenticatedSession,
                    supportsReceipts: state.capabilities.contains(.privateMediaReceipts),
                    supportsExtendedFragmentSets: state.capabilities.contains(.extendedFragmentSets)
                )
            }
            return .blocked
        case .timedOut:
            // watchOS never sends the legacy clear-media fallback. A sticky pin
            // is still persisted to prevent another platform from downgrading.
            return .blocked
        }
    }

    func persistedSigningKey(for noisePublicKey: Data) -> Data? {
        guard noisePublicKey.count == 32 else { return nil }
        return store.load(
            fingerprint: Self.fingerprint(noisePublicKey)
        )?.signingPublicKey
    }

    func permitsAnnouncementRelay(
        noisePublicKey: Data,
        announcedSigningKey: Data,
        currentSigningKey: Data?
    ) -> Bool {
        guard noisePublicKey.count == 32, announcedSigningKey.count == 32 else {
            return false
        }
        let trustedKey = persistedSigningKey(for: noisePublicKey) ?? currentSigningKey
        return trustedKey == nil || trustedKey == announcedSigningKey
    }

    func clear(_ peerID: PeerID) {
        sessions.removeValue(forKey: peerID)
    }

    func clearAll() {
        sessions.removeAll()
    }

    private func valid(
        _ session: WatchAuthenticatedNoiseSession,
        for peerID: PeerID
    ) -> Bool {
        session.remoteStaticKey.count == 32
            && session.sessionToken.count == 32
            && session.sessionToken.contains(where: { $0 != 0 })
            && PeerID(publicKey: session.remoteStaticKey) == peerID
    }

    private static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
