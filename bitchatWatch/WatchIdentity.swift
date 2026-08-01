//
// WatchIdentity.swift
// bitchat
//
// Mirrors the Android wear identity model (wear/.../mesh/WearMeshService.kt):
// - own Noise static keypair (Curve25519.KeyAgreement) + Ed25519 signing key,
//   persisted locally (Android: EncryptedSharedPreferences; here: Keychain)
// - peerID = 16-hex prefix of the Noise public key fingerprint
// - nickname persisted in UserDefaults ("nickname"/"nickname_chosen" keys,
//   same as Android's bitchat_watch_prefs), default "watch-" + peerID[0..<4]
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation
import os
import Security

final class WatchIdentity: KeychainManagerProtocol {

    static let shared = WatchIdentity()

    private let noisePrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let signingPrivateKey: Curve25519.Signing.PrivateKey
    private static let logger = Logger(subsystem: "chat.bitchat.watch", category: "keychain")

    let peerID: PeerID
    let hasPersistentKeys: Bool
    private(set) var nickname: String

    private init() {
        let noiseResult = Self.loadOrCreateKey(
            account: "identity_noiseStaticKey",
            create: { Curve25519.KeyAgreement.PrivateKey().rawRepresentation },
            isValid: {
                (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0)) != nil
            }
        )
        let signingResult = Self.loadOrCreateKey(
            account: "identity_ed25519SigningKey",
            create: { Curve25519.Signing.PrivateKey().rawRepresentation },
            isValid: {
                (try? Curve25519.Signing.PrivateKey(rawRepresentation: $0)) != nil
            }
        )
        let parsedNoise = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: noiseResult.data
        )
        let parsedSigning = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: signingResult.data
        )
        noisePrivateKey = parsedNoise ?? Curve25519.KeyAgreement.PrivateKey()
        signingPrivateKey = parsedSigning ?? Curve25519.Signing.PrivateKey()
        hasPersistentKeys = noiseResult.isPersistent
            && signingResult.isPersistent
            && parsedNoise != nil
            && parsedSigning != nil
        peerID = PeerID(publicKey: noisePrivateKey.publicKey.rawRepresentation)

        let defaults = UserDefaults.standard
        let storedDefault = defaults.string(forKey: "nickname")
        let storedKeychain = Self.load(account: Self.nicknameAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(Self.sanitizeNickname)
        if let sanitized = storedDefault.flatMap(Self.sanitizeNickname)
            ?? storedKeychain {
            nickname = sanitized
            defaults.set(sanitized, forKey: "nickname")
            let chosen = defaults.bool(forKey: "nickname_chosen")
                || storedKeychain != nil
            defaults.set(chosen, forKey: "nickname_chosen")
            if chosen {
                _ = Self.save(
                    account: Self.nicknameAccount,
                    data: Data(sanitized.utf8)
                )
            }
        } else {
            // Android: "watch-" + myPeerID.take(4)
            nickname = "watch-" + peerID.id.prefix(4)
            defaults.set(nickname, forKey: "nickname")
            defaults.set(false, forKey: "nickname_chosen")
        }
    }

    // MARK: - Public accessors

    var noisePublicKeyData: Data { noisePrivateKey.publicKey.rawRepresentation }
    var signingPublicKeyData: Data { signingPrivateKey.publicKey.rawRepresentation }
    var noisePrivateKeyValue: Curve25519.KeyAgreement.PrivateKey { noisePrivateKey }
    var fingerprint: String {
        SHA256.hash(data: noisePublicKeyData).map { String(format: "%02x", $0) }.joined()
    }
    var nicknameChosen: Bool {
        UserDefaults.standard.bool(forKey: "nickname_chosen")
            || Self.load(account: Self.nicknameAccount) != nil
    }
    /// 8-byte routing sender ID derived from the 16-hex peer ID.
    var peerIDData: Data { peerID.routingData ?? Data(peerID.id.utf8.prefix(8)) }

    func sign(_ data: Data) -> Data? {
        // Modern CryptoKit: signature(for: DataProtocol) returns the raw
        // 64-byte signature Data directly.
        try? signingPrivateKey.signature(for: data)
    }

    func setNickname(_ newNickname: String) {
        guard let sanitized = Self.sanitizeNickname(newNickname) else { return }
        nickname = sanitized
        UserDefaults.standard.set(sanitized, forKey: "nickname")
        // Confirming the generated default is still a completed setup. The
        // previous early return made that choice reappear on every launch.
        UserDefaults.standard.set(true, forKey: "nickname_chosen")
        let status = Self.save(
            account: Self.nicknameAccount,
            data: Data(sanitized.utf8)
        )
        if status != errSecSuccess {
            Self.logger.error("Failed to persist nickname: \(status, privacy: .public)")
        }
    }

    private static func sanitizeNickname(_ nickname: String) -> String? {
        let normalized = nickname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return String(normalized.prefix(24))
    }

    // MARK: - Keychain (device-local, mirrors iOS KeychainManager accessibility)

    private static let keychainService = "chat.bitchat.watch.identity"
    private static let nicknameAccount = "profile_nickname"

    private struct KeyLoadResult {
        let data: Data
        let isPersistent: Bool
    }

    private static func loadOrCreateKey(
        account: String,
        create: () -> Data,
        isValid: (Data) -> Bool
    ) -> KeyLoadResult {
        if let data = load(account: account), isValid(data) {
            return KeyLoadResult(data: data, isPersistent: true)
        }
        let data = create()
        let status = save(account: account, data: data)
        if status != errSecSuccess {
            logger.error("Failed to persist identity key: \(status, privacy: .public)")
        }
        return KeyLoadResult(data: data, isPersistent: status == errSecSuccess)
    }

    private static func load(account: String, service: String = keychainService) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func save(
        account: String,
        data: Data,
        service: String = keychainService,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessible
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func readResult(account: String, service: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .otherError(status) }
            return .success(data)
        case errSecItemNotFound:
            return .itemNotFound
        case errSecInteractionNotAllowed:
            return .deviceLocked
        case errSecAuthFailed:
            return .authenticationFailed
        case errSecNotAvailable, -34018:
            return .accessDenied
        default:
            return .otherError(status)
        }
    }

    // MARK: - KeychainManagerProtocol

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        Self.save(account: key, data: keyData) == errSecSuccess
    }

    func getIdentityKey(forKey key: String) -> Data? {
        Self.load(account: key)
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func deleteAllKeychainData() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func secureClear(_ data: inout Data) {
        data.resetBytes(in: data.startIndex..<data.endIndex)
        data.removeAll(keepingCapacity: false)
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        Self.load(account: "identity_noiseStaticKey") != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        Self.readResult(account: key, service: Self.keychainService)
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        let status = Self.save(account: key, data: keyData)
        if status == errSecSuccess { return .success }
        if status == errSecDuplicateItem { return .duplicateItem }
        if status == errSecInteractionNotAllowed { return .deviceLocked }
        if status == errSecNotAvailable || status == -34018 { return .accessDenied }
        if status == errSecDiskFull { return .storageFull }
        return .otherError(status)
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        _ = Self.save(
            account: key,
            data: data,
            service: service,
            accessible: accessible ?? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    func load(key: String, service: String) -> Data? {
        Self.load(account: key, service: service)
    }

    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        Self.readResult(account: key, service: service)
    }

    func delete(key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
