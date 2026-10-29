//
// WatchMeshRuntimePolicy.swift
// bitchat
//

import Foundation

/// Pure watchOS transport policy. Wear OS can run a foreground service and
/// advertise; watchOS cannot, so we approximate its persistent eight-link
/// topology with system-owned connection requests and a filtered scan that
/// remains armed while capacity is available.
enum WatchMeshRuntimePolicy {
    static let maximumPhysicalLinks = 8
    static let maximumBackgroundConnections = 2
    static let maximumConcurrentConnectionAttempts = 3
    static let peerPresenceTimeout: TimeInterval = 180
    static let scanWatchdogInterval: TimeInterval = 30
    static let foregroundScanStaleInterval: TimeInterval = 120
    static let centralRecoveryStaleInterval: TimeInterval = 180
    static let centralRebuildMinimumInterval: TimeInterval = 300
    static let candidateCollectionInterval: TimeInterval = 1
    static let candidateRetentionInterval: TimeInterval = 30
    static let connectionAttemptTimeout: TimeInterval = 30
    /// Freshly discovered peripherals weaker than this are not worth a
    /// connection slot: at that range attempts time out for hours without
    /// ever completing (observed -90...-95 dBm perpetual failures).
    static let minimumCandidateRSSI = -90

    /// Per-peripheral cooldown after consecutive connection failures. Without
    /// it, a handful of unreachable advertisers permanently occupy all
    /// concurrent connection slots and starve healthy links — including the
    /// foreground-resume path, which then appears to "find no peers".
    static func connectionRetryCooldown(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures >= 2 else { return 0 }
        let exponent = min(consecutiveFailures - 1, 6)
        return min(600, TimeInterval(15 * (1 << exponent)))
    }

    /// A link that worked this recently was a backbone relay, not a dead
    /// candidate: allow one otherwise-cooled retry. Repeated failures must
    /// resume backoff or a departed relay can monopolize every connection
    /// slot for the full recent-success window.
    static let recentSuccessReconnectBypass: TimeInterval = 15 * 60
    private static let recentSuccessBypassFailureLimit = 2

    static func shouldSkipConnectionAttempt(
        consecutiveFailures: Int,
        lastFailureAt: Date?,
        lastSuccessfulAt: Date?,
        now: Date = Date()
    ) -> Bool {
        if consecutiveFailures <= recentSuccessBypassFailureLimit,
           let lastSuccessfulAt,
           now.timeIntervalSince(lastSuccessfulAt) < recentSuccessReconnectBypass {
            return false
        }
        let cooldown = connectionRetryCooldown(
            consecutiveFailures: consecutiveFailures
        )
        guard cooldown > 0, let lastFailureAt else { return false }
        return now.timeIntervalSince(lastFailureAt) < cooldown
    }
    static let serviceDiscoveryTimeout: TimeInterval = 15
    static let characteristicDiscoveryTimeout: TimeInterval = 15
    static let notificationSubscriptionTimeout: TimeInterval = 15

    static func shouldKeepDiscoveryArmed(physicalLinks: Int) -> Bool {
        physicalLinks < maximumPhysicalLinks
    }

    /// Timely alerts and background discovery consume the same five-opportunity
    /// watchOS budget. Discovery is therefore foreground-only; established
    /// connections and explicit reconnect requests remain system-owned when the
    /// wrist is lowered.
    static func shouldRunDiscovery(
        isAppInForeground: Bool,
        physicalLinks: Int
    ) -> Bool {
        isAppInForeground && shouldKeepDiscoveryArmed(physicalLinks: physicalLinks)
    }

    static func canStartConnection(
        physicalLinks: Int,
        pendingAttempts: Int,
        isAppInForeground: Bool = true
    ) -> Bool {
        let limit = isAppInForeground
            ? maximumPhysicalLinks
            : maximumBackgroundConnections
        return physicalLinks + pendingAttempts < limit
            && pendingAttempts < maximumConcurrentConnectionAttempts
    }

    /// A background connect request is handed to Core Bluetooth immediately;
    /// the OS can retain it while the app is suspended. Foreground retries use
    /// bounded backoff to avoid thrashing a failing radio stack.
    static func reconnectDelay(isAppInForeground: Bool, attempt: Int) -> TimeInterval {
        guard isAppInForeground else { return 0 }
        let exponent = min(max(attempt - 1, 0), 4)
        return min(30, TimeInterval(1 << exponent))
    }

    /// Alert-only background links intentionally suppress announcements.
    /// Their absence is therefore not evidence that an authenticated peer has
    /// disappeared. Re-evaluate presence after full-mesh traffic resumes.
    static func shouldExpirePeerPresence(isAppInForeground: Bool) -> Bool {
        isAppInForeground
    }

    /// Discovery is not a subscription: keep the existing receive path until
    /// Core Bluetooth confirms the alert lane is actually notifying. This
    /// also preserves the only wake path for legacy peers.
    static func shouldQuietMeshLaneInBackground(
        hasAlertLane: Bool,
        isAlertLaneSubscribed: Bool
    ) -> Bool {
        hasAlertLane && isAlertLaneSubscribed
    }
}

/// Keep one pending system refresh rather than postponing it on every scene
/// transition. watchOS decides whether and when to grant the request.
struct WatchBackgroundRefreshSchedule {
    static let identifier = "chat.bitchat.watch.mesh-refresh"
    static let interval: TimeInterval = 15 * 60
    private(set) var preferredDate: Date?

    mutating func requestDate(now: Date = Date()) -> Date? {
        if let preferredDate, preferredDate > now { return nil }
        let date = now.addingTimeInterval(Self.interval)
        preferredDate = date
        return date
    }

    mutating func requestFailed(for date: Date) {
        guard preferredDate == date else { return }
        preferredDate = nil
    }

    mutating func taskDelivered() {
        preferredDate = nil
    }
}

enum WatchConnectionPhase: String, CaseIterable {
    case connecting
    case services
    case characteristics
    case subscribing

    var timeout: TimeInterval {
        switch self {
        case .connecting:
            WatchMeshRuntimePolicy.connectionAttemptTimeout
        case .services:
            WatchMeshRuntimePolicy.serviceDiscoveryTimeout
        case .characteristics:
            WatchMeshRuntimePolicy.characteristicDiscoveryTimeout
        case .subscribing:
            WatchMeshRuntimePolicy.notificationSubscriptionTimeout
        }
    }
}

struct WatchDiscoveryCandidateScore: Equatable {
    let id: UUID
    let advertisedPeerIsConnected: Bool
    let previouslySuccessful: Bool
    let lastAttempt: Date?
    let rssi: Int
    let discoveredAt: Date
}

struct WatchBackgroundRelayCandidate: Equatable {
    let id: UUID
    let peerID: String?
    let supportsAlertLane: Bool
    let rssi: Int
    let connectedAt: Date
}

extension WatchMeshRuntimePolicy {
    /// watchOS maintains at most two BLE connections for an app in the
    /// background. Prefer dedicated alert-capable links, avoid two physical
    /// links to the same authenticated peer, then favor radio quality and
    /// long-lived connections.
    static func selectBackgroundRelays(
        _ candidates: [WatchBackgroundRelayCandidate]
    ) -> [WatchBackgroundRelayCandidate] {
        let ranked = candidates.sorted { left, right in
            if left.supportsAlertLane != right.supportsAlertLane {
                return left.supportsAlertLane
            }
            if (left.peerID != nil) != (right.peerID != nil) {
                return left.peerID != nil
            }
            if left.rssi != right.rssi { return left.rssi > right.rssi }
            return left.connectedAt < right.connectedAt
        }
        var selected: [WatchBackgroundRelayCandidate] = []
        var selectedPeerIDs = Set<String>()
        for candidate in ranked {
            guard selected.count < maximumBackgroundConnections else { break }
            if let peerID = candidate.peerID, selectedPeerIDs.contains(peerID) {
                continue
            }
            selected.append(candidate)
            if let peerID = candidate.peerID { selectedPeerIDs.insert(peerID) }
        }
        if selected.count < maximumBackgroundConnections {
            for candidate in ranked where !selected.contains(candidate) {
                selected.append(candidate)
                if selected.count == maximumBackgroundConnections { break }
            }
        }
        return selected
    }

    /// Android fills several client slots while using stable advertised peer
    /// identity to avoid duplicate links. Core Bluetooth does not expose a
    /// controllable connection scheduler, so the watch briefly pools results
    /// and applies the same priorities before issuing connection requests.
    static func rankCandidates(
        _ candidates: [WatchDiscoveryCandidateScore]
    ) -> [WatchDiscoveryCandidateScore] {
        candidates.sorted { left, right in
            if left.advertisedPeerIsConnected != right.advertisedPeerIsConnected {
                return !left.advertisedPeerIsConnected
            }
            if left.previouslySuccessful != right.previouslySuccessful {
                return left.previouslySuccessful
            }
            let leftAttempt = left.lastAttempt ?? .distantPast
            let rightAttempt = right.lastAttempt ?? .distantPast
            if leftAttempt != rightAttempt {
                return leftAttempt < rightAttempt
            }
            if left.rssi != right.rssi {
                return left.rssi > right.rssi
            }
            return left.discoveredAt < right.discoveredAt
        }
    }
}
