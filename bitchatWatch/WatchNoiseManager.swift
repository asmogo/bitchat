//
// WatchNoiseManager.swift
// bitchat
//
// Small watch-owned Noise XX session coordinator. The crypto implementation
// is shared verbatim with the iOS target; this layer only owns collision
// policy and validates that the authenticated static key matches the packet's
// claimed mesh identity.
//

import BitFoundation
import CryptoKit
import Foundation

struct WatchNoiseHandshakeResult {
    let response: Data?
    let established: Bool
}

struct WatchAuthenticatedNoiseSession: Equatable {
    let remoteStaticKey: Data
    let sessionToken: Data
}

enum WatchNoiseError: Error {
    case unexpectedHandshake
    case peerIdentityMismatch
}

final class WatchNoiseManager {
    private let identity: WatchIdentity
    private var sessions: [PeerID: NoiseSession] = [:]
    private var lastMessageOne: [PeerID: Data] = [:]
    private var cachedMessageTwo: [PeerID: Data] = [:]

    init(identity: WatchIdentity) {
        self.identity = identity
    }

    func hasSession(with peerID: PeerID) -> Bool {
        sessions[peerID] != nil
    }

    func isEstablished(with peerID: PeerID) -> Bool {
        sessions[peerID]?.isEstablished() == true
    }

    func initiate(with peerID: PeerID) throws -> Data? {
        if let session = sessions[peerID] {
            if session.isEstablished() || session.getState() == .handshaking {
                return nil
            }
        }
        let session = makeSession(peerID: peerID, role: .initiator)
        sessions[peerID] = session
        return try session.startHandshake()
    }

    func process(_ message: Data, from peerID: PeerID) throws -> WatchNoiseHandshakeResult {
        let looksLikeMessageOne = message.count == 32
        var session = sessions[peerID]

        if looksLikeMessageOne {
            if let existing = session, existing.getState() == .handshaking {
                if existing.role == .responder {
                    if lastMessageOne[peerID] == message {
                        return WatchNoiseHandshakeResult(
                            response: cachedMessageTwo[peerID],
                            established: false
                        )
                    }
                } else if identity.peerID.id < peerID.id {
                    // Deterministic crossed-initiation policy: the lower peer
                    // ID remains initiator, the higher peer ID yields.
                    return WatchNoiseHandshakeResult(response: nil, established: false)
                }
            }

            session?.reset()
            session = makeSession(peerID: peerID, role: .responder)
            sessions[peerID] = session
        }

        guard let session else { throw WatchNoiseError.unexpectedHandshake }
        let wasEstablished = session.isEstablished()
        let response = try session.processHandshakeMessage(message)
        if looksLikeMessageOne {
            lastMessageOne[peerID] = message
            cachedMessageTwo[peerID] = response
        }
        let established = !wasEstablished && session.isEstablished()

        if established {
            guard let remoteKey = session.getRemoteStaticPublicKey(),
                  PeerID(publicKey: remoteKey.rawRepresentation) == peerID else {
                session.reset()
                sessions.removeValue(forKey: peerID)
                throw WatchNoiseError.peerIdentityMismatch
            }
            lastMessageOne.removeValue(forKey: peerID)
            cachedMessageTwo.removeValue(forKey: peerID)
        }

        return WatchNoiseHandshakeResult(response: response, established: established)
    }

    func encrypt(_ plaintext: Data, for peerID: PeerID) throws -> Data {
        guard let session = sessions[peerID], session.isEstablished() else {
            throw NoiseSessionError.notEstablished
        }
        return try session.encrypt(plaintext)
    }

    func encrypt(
        _ plaintext: Data,
        for peerID: PeerID,
        expectedSession: WatchAuthenticatedNoiseSession
    ) throws -> Data {
        guard authenticatedSession(for: peerID) == expectedSession,
              let session = sessions[peerID], session.isEstablished() else {
            throw NoiseSessionError.notEstablished
        }
        return try session.encrypt(plaintext)
    }

    func decrypt(_ ciphertext: Data, from peerID: PeerID) throws -> Data {
        guard let session = sessions[peerID], session.isEstablished() else {
            throw NoiseSessionError.notEstablished
        }
        return try session.decrypt(ciphertext)
    }

    func decryptWithSession(
        _ ciphertext: Data,
        from peerID: PeerID
    ) throws -> (plaintext: Data, session: WatchAuthenticatedNoiseSession) {
        guard let authenticated = authenticatedSession(for: peerID),
              let session = sessions[peerID], session.isEstablished() else {
            throw NoiseSessionError.notEstablished
        }
        let plaintext = try session.decrypt(ciphertext)
        guard authenticatedSession(for: peerID) == authenticated else {
            throw NoiseSessionError.notEstablished
        }
        return (plaintext, authenticated)
    }

    func authenticatedSession(for peerID: PeerID) -> WatchAuthenticatedNoiseSession? {
        guard let session = sessions[peerID], session.isEstablished(),
              let remoteStatic = session.getRemoteStaticPublicKey()?.rawRepresentation,
              PeerID(publicKey: remoteStatic) == peerID,
              let token = session.getHandshakeHash(), token.count == 32,
              token.contains(where: { $0 != 0 }) else {
            return nil
        }
        return WatchAuthenticatedNoiseSession(
            remoteStaticKey: remoteStatic,
            sessionToken: token
        )
    }

    func fingerprint(for peerID: PeerID) -> String? {
        guard let key = sessions[peerID]?.getRemoteStaticPublicKey()?.rawRepresentation else {
            return nil
        }
        return SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    func clear(_ peerID: PeerID) {
        sessions.removeValue(forKey: peerID)?.reset()
        lastMessageOne.removeValue(forKey: peerID)
        cachedMessageTwo.removeValue(forKey: peerID)
    }

    func clearAll() {
        for session in sessions.values { session.reset() }
        sessions.removeAll()
        lastMessageOne.removeAll()
        cachedMessageTwo.removeAll()
    }

    private func makeSession(peerID: PeerID, role: NoiseRole) -> NoiseSession {
        NoiseSession(
            peerID: peerID,
            role: role,
            keychain: identity,
            localStaticKey: identity.noisePrivateKeyValue
        )
    }
}
