//
// WatchBLEController.swift
// bitchat
//
// A central-role watchOS mesh node. watchOS cannot advertise as a BLE
// peripheral, but once connected this controller participates in routing,
// signed public chat, Noise XX direct messages, receipts, and media.
//

import BitFoundation
import CoreBluetooth
import CryptoKit
import Foundation
import os
import WatchKit

enum WatchDemoMode {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--watch-screenshot-demo")
        #else
        false
        #endif
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}

struct WatchPeer: Identifiable, Equatable {
    let peerID: PeerID
    var nickname: String
    var noisePublicKey: Data
    var signingPublicKey: Data
    var lastSeen: Date
    var capabilities: PeerCapabilities
    var id: String { peerID.id }
}

struct WatchChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let sender: String
    let senderPeerID: PeerID?
    let content: String
    let timestamp: Date
    let isSelf: Bool
    let isPrivate: Bool
    let conversationPeerID: PeerID?
    var status: String
    var media: WatchMediaAttachment?
    var supportsReceipts = true

    @discardableResult
    mutating func updateDeliveryStatus(_ newStatus: String) -> Bool {
        guard status != newStatus, status != "read",
              status != "delivered" || newStatus == "read" else { return false }
        status = newStatus
        return true
    }
}

final class WatchBLEController: NSObject, ObservableObject {

    #if DEBUG
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A")
    #else
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    #endif
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    static let alertCharacteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5E")

    let identity = WatchIdentity.shared
    private lazy var noise = WatchNoiseManager(identity: identity)
    private let trustStore = WatchTrustStore.shared
    private let logger = Logger(subsystem: "chat.bitchat.watch", category: "mesh")

    @Published private(set) var running = false
    @Published private(set) var centralState = "unknown"
    @Published private(set) var linkCount = 0
    @Published private(set) var directLinkCount = 0
    @Published private(set) var knownPeripheralCount = 0
    @Published private(set) var connectingLinkCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var connectionStageSummary = "idle"
    @Published private(set) var recoveryCount = 0
    @Published private(set) var phaseTimeoutCount = 0
    @Published private(set) var lastRecoveryReason = "none"
    @Published private(set) var peers: [WatchPeer] = []
    @Published private(set) var messages: [WatchChatMessage] = [] {
        didSet { scheduleConversationPersistence() }
    }
    @Published private(set) var privateMessages: [String: [WatchChatMessage]] = [:] {
        didSet { scheduleConversationPersistence() }
    }
    @Published private(set) var unreadDms: [String: Int] = [:] {
        didSet { scheduleConversationPersistence() }
    }
    @Published private(set) var rxBytes = 0
    @Published private(set) var txBytes = 0
    @Published private(set) var logLines: [String] = []
    @Published private(set) var trustRevision = 0
    @Published private(set) var activePublicVoiceTalker: String?
    @Published private(set) var backgroundAlertState = "idle"
    @Published private(set) var notificationAuthorizationState = "checking"

    private var centralManager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var writableCharacteristics: [UUID: CBCharacteristic] = [:]
    private var alertCharacteristics: [UUID: CBCharacteristic] = [:]
    private var announcedReadyLinks: Set<UUID> = []
    private var pendingWrites: [UUID: PendingWriteQueue] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectWorkItems: [UUID: DispatchWorkItem] = [:]
    private var recoveryVerificationWorkItems: [UUID: DispatchWorkItem] = [:]
    private var connectionRequestedAt: [UUID: Date] = [:]
    private var peripheralLastDiscoveredAt: [UUID: Date] = [:]
    private var peripheralRSSI: [UUID: Int] = [:]
    private var connectedAt: [UUID: Date] = [:]
    private var retiredDuplicateLinks: Set<UUID> = []
    private var backgroundParkedLinks: Set<UUID> = []
    private var lastDiscoveryAt = Date.distantPast
    private var lastBluetoothProgressAt = Date.distantPast
    private var lastCentralRebuildAt = Date.distantPast
    private var consecutivePhaseTimeouts = 0
    private var scanWatchdog: DispatchSourceTimer?
    private var candidateDrainWorkItem: DispatchWorkItem?
    private var connectionPhases: [UUID: ConnectionPhaseState] = [:]
    private var discoveryCandidates: [UUID: DiscoveryCandidate] = [:]
    private var pendingTimelyAlertSignalIDs: Set<String> = []
    /// Core Bluetooth notification changes complete asynchronously. Keep the
    /// operation currently in flight per link and converge to the latest
    /// lifecycle state from its callback. In particular, a late background
    /// unsubscribe must never leave the foreground mesh lane disabled.
    private var meshNotificationRequests: [UUID: Bool] = [:]
    private var meshNotificationTimeoutWorkItems: [UUID: DispatchWorkItem] = [:]
    private var meshNotificationFailureCounts: [UUID: Int] = [:]
    /// True while a Bluetooth-alert wake intentionally holds the full-mesh
    /// lane open to drain deferred traffic.
    private var backgroundDrainActive = false
    private var backgroundDrainStartedAt = Date.distantPast
    private let fragmentAssembler = WatchFragmentAssembler()
    private let conversationStore = WatchConversationStore()
    private let knownPeerStore = WatchKnownPeerStore()
    private let peripheralHistory = WatchPeripheralHistoryStore()
    private let privateMediaReceipts = PrivateMediaReceiptLedger()
    private let gossipStore = WatchGossipStore()
    private lazy var peerSecurity = WatchPeerSecurityCoordinator(
        store: WatchKeychainPeerStateStore(keychain: identity)
    )
    private var seenPacketHashes: [Data: Date] = [:]
    private var seenMessageIDs: Set<String> = []
    private var directPeerByLink: [UUID: PeerID] = [:]
    private var lastAnnounceBackAt: [String: Date] = [:]
    private var lastAnnounceSentAt = Date.distantPast
    private var lastPublicSyncAt = Date.distantPast
    private var lastPublicSyncByLink: [UUID: Date] = [:]
    private var syncResponseTimes: [PeerID: [Date]] = [:]
    private var announceHeartbeat: DispatchSourceTimer?
    private var lastHandshakeAttemptAt: [String: Date] = [:]
    private var deferredEncryptedPackets: [PeerID: [BitchatPacket]] = [:]
    private var sentReadReceiptIDs: Set<String> = []
    private var fragmentRecoveryWorkItem: DispatchWorkItem?
    private var lastHousekeeping = Date.distantPast
    private var lastGrantedRuntimeMaintenance = Date.distantPast
    private var activeDMPeer: PeerID?
    private var isPublicConversationActive = false
    /// Transport foreground deliberately includes the inactive/Always-On
    /// state so wrist flicks do not tear down every Bluetooth link.
    private var isAppInForeground = false
    /// Notification/read semantics require an actually interactive scene.
    /// A dimmed or inactive conversation is not visible to the user.
    private var isAppInteractive = false
    private var isRestoringConversation = true
    private var conversationPersistenceWorkItem: DispatchWorkItem?
    private lazy var liveVoiceCoordinator = WatchLiveVoiceCoordinator(delegate: self)
    private let bluetoothAlertGate = WatchBluetoothAlertGate()

    private struct ConnectionPhaseState {
        let phase: WatchConnectionPhase
        let startedAt: Date
    }

    private struct DiscoveryCandidate {
        let peripheral: CBPeripheral
        var rssi: Int
        var discoveredAt: Date
        var advertisedPeerID: String?
    }

    private struct PendingNoisePayload {
        let data: Data
        let messageID: String?
    }
    private var pendingNoisePayloads: [PeerID: [PendingNoisePayload]] = [:]
    private var pendingPrivateMediaPayloads: [PeerID: [PendingNoisePayload]] = [:]
    private var privateMediaRetryPayloads: [String: (peerID: PeerID, data: Data)] = [:]
    private var privateMediaRetryAttempts: [String: Int] = [:]
    private var privateMediaRetryWorkItems: [String: DispatchWorkItem] = [:]

    private struct PendingAnnouncement {
        let packet: BitchatPacket
        let announcement: WatchAnnouncementPacket
        let linkUUID: UUID
    }
    private var pendingAnnouncements: [PeerID: PendingAnnouncement] = [:]

    private enum WritePriority {
        case normal
        case realtime
    }

    /// Live voice bypasses queued file fragments, while both classes remain
    /// bounded by the same per-link byte budget.
    private struct PendingWriteQueue {
        private var liveFrames: [Data] = []
        private var liveHead = 0
        private var normalFrames: [Data] = []
        private var normalHead = 0
        private(set) var byteCount = 0

        var isEmpty: Bool {
            liveHead >= liveFrames.count && normalHead >= normalFrames.count
        }

        mutating func enqueue(
            _ data: Data,
            priority: WritePriority,
            maximumBytes: Int
        ) -> Bool {
            guard data.count <= maximumBytes - byteCount else { return false }
            switch priority {
            case .realtime: liveFrames.append(data)
            case .normal: normalFrames.append(data)
            }
            byteCount += data.count
            return true
        }

        mutating func dequeue() -> Data? {
            let data: Data
            if liveHead < liveFrames.count {
                data = liveFrames[liveHead]
                liveHead += 1
                if liveHead >= 64, liveHead * 2 >= liveFrames.count {
                    liveFrames.removeFirst(liveHead)
                    liveHead = 0
                }
            } else if normalHead < normalFrames.count {
                data = normalFrames[normalHead]
                normalHead += 1
                if normalHead >= 64, normalHead * 2 >= normalFrames.count {
                    normalFrames.removeFirst(normalHead)
                    normalHead = 0
                }
            } else {
                return nil
            }
            byteCount -= data.count
            return data
        }
    }

    private static let logFileName = "mesh.log"
    private static let maximumLogFileBytes: UInt64 = 512 * 1024
    private var logFileHandle: FileHandle?
    private var logFileBytes: UInt64 = 0

    /// Android accepts public text up to its bounded 1 MiB fragment assembly
    /// ceiling. Keep the watch receiver interoperable instead of silently
    /// discarding otherwise valid signed Android messages above 400 bytes.
    static let maxPublicContentBytes = FileTransferLimits.maxPayloadBytes
    /// PrivateMessagePacket has a one-byte TLV length on both platforms.
    static let maxPrivateContentBytes = 255
    private static let publicFragmentSpacing: TimeInterval = 0.030
    private static let directedFragmentSpacing: TimeInterval = 0.025
    private static let maximumQueuedWriteBytes =
        FileTransferLimits.maxFramedFileBytes * 2
    private static let maxTimelineMessages = 250
    private static let maxDirectMessagesPerPeer = 200
    private static let maxPendingNoisePayloadsPerPeer = 16
    private static let maxPeerCount = 128
    private static let maxAnnouncedDirectNeighbors = 10
    private static let bluetoothAlertTimeoutNanoseconds: UInt64 = 4_000_000_000
    private static let bluetoothAlertMinimumDrainNanoseconds: UInt64 = 1_500_000_000
    private static let delegateDrivenDrainSeconds: TimeInterval = 4
    private static let meshNotificationTransitionTimeout: TimeInterval = 8
    /// Apple grants only a few seconds for a Bluetooth-alert task. Keep the
    /// entire drain inside that runtime instead of scheduling work after the
    /// task returns and risking immediate suspension.
    private static let backgroundDrainMaxSeconds: TimeInterval = 4
    private static let backgroundDrainPollNanoseconds: UInt64 = 200_000_000
    private static let foregroundAnnounceInterval: TimeInterval = 30
    /// Suspended processes cannot run timers, so background presence rides on
    /// granted Bluetooth-alert runtime, bounded to one announce per interval.
    private static let backgroundAnnounceInterval: TimeInterval = 60
    private static let directAnnounceResponseInterval: TimeInterval = 60
    private static let maxCrossPlatformFragments =
        FragmentationLimits.crossPlatformMaxFragments
    private static let maxExtendedFragments = 10_000
    private static var centralRestoreIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "chat.bitchat.watch") + ".ble-central"
    }

    override init() {
        super.init()
        if WatchDemoMode.isEnabled {
            seedScreenshotDemo()
        } else {
            let snapshot = conversationStore.load()
            messages = Array(snapshot.messages.suffix(Self.maxTimelineMessages))
            privateMessages = snapshot.privateMessages.mapValues {
                Array($0.suffix(Self.maxDirectMessagesPerPeer))
            }
            unreadDms = snapshot.unreadDms.filter {
                privateMessages[$0.key]?.isEmpty == false && $0.value > 0
            }
            seenMessageIDs = Set(messages.map(\.id))
            for thread in privateMessages.values {
                seenMessageIDs.formUnion(thread.map(\.id))
            }
            migratePrivateMediaReceiptsFromConversation()
            restorePendingPrivateMediaRetries()
            enforceMediaRetention()
            pruneUnreferencedMedia()
        }
        isRestoringConversation = false
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        guard identity.hasPersistentKeys else {
            centralState = "identityUnavailable"
            log("start rejected: secure identity is unavailable")
            return
        }
        running = true
        if WatchDemoMode.isEnabled {
            centralState = "poweredOn"
            linkCount = 2
            return
        }
        log("start: mesh node \(identity.peerID.id) (\(identity.nickname))")
        refreshNotificationAuthorizationState()
        lastBluetoothProgressAt = Date()
        refreshScanWatchdog()
        makeCentralManager()
    }

    private func makeCentralManager() {
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    Self.centralRestoreIdentifier
            ]
        )
    }

    func stop() {
        guard running else { return }
        flushConversationPersistence()
        running = false
        announceHeartbeat?.cancel()
        announceHeartbeat = nil
        scanWatchdog?.cancel()
        scanWatchdog = nil
        candidateDrainWorkItem?.cancel()
        candidateDrainWorkItem = nil
        log("stop")
        try? logFileHandle?.close()
        logFileHandle = nil
        logFileBytes = 0
        centralManager?.stopScan()
        for peripheral in peripherals.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
        writableCharacteristics.removeAll()
        alertCharacteristics.removeAll()
        announcedReadyLinks.removeAll()
        directPeerByLink.removeAll()
        pendingWrites.removeAll()
        for workItem in reconnectWorkItems.values { workItem.cancel() }
        reconnectWorkItems.removeAll()
        for workItem in recoveryVerificationWorkItems.values { workItem.cancel() }
        recoveryVerificationWorkItems.removeAll()
        reconnectAttempts.removeAll()
        connectionRequestedAt.removeAll()
        connectionPhases.removeAll()
        discoveryCandidates.removeAll()
        for workItem in meshNotificationTimeoutWorkItems.values { workItem.cancel() }
        meshNotificationTimeoutWorkItems.removeAll()
        meshNotificationRequests.removeAll()
        meshNotificationFailureCounts.removeAll()
        peripheralLastDiscoveredAt.removeAll()
        peripheralRSSI.removeAll()
        connectedAt.removeAll()
        retiredDuplicateLinks.removeAll()
        backgroundParkedLinks.removeAll()
        pendingTimelyAlertSignalIDs.removeAll()
        pendingNoisePayloads.removeAll()
        pendingPrivateMediaPayloads.removeAll()
        for workItem in privateMediaRetryWorkItems.values { workItem.cancel() }
        privateMediaRetryWorkItems.removeAll()
        privateMediaRetryPayloads.removeAll()
        privateMediaRetryAttempts.removeAll()
        pendingAnnouncements.removeAll()
        deferredEncryptedPackets.removeAll()
        peerSecurity.clearAll()
        lastHandshakeAttemptAt.removeAll()
        fragmentRecoveryWorkItem?.cancel()
        fragmentRecoveryWorkItem = nil
        liveVoiceCoordinator.reset()
        noise.clearAll()
        linkCount = 0
        directLinkCount = 0
        knownPeripheralCount = 0
        connectingLinkCount = 0
        isScanning = false
        connectionStageSummary = "idle"
        consecutivePhaseTimeouts = 0
        backgroundDrainActive = false
        backgroundAlertState = "idle"
    }

    func setApplicationState(isForeground: Bool, isInteractive: Bool) {
        self.isAppInteractive = isForeground && isInteractive
        if self.isAppInteractive {
            refreshNotificationAuthorizationState()
        }
        setAppInForeground(isForeground)
    }

    func refreshNotificationAuthorizationState() {
        WatchNotifications.authorizationSummary { [weak self] summary in
            guard let self else { return }
            let changed = self.notificationAuthorizationState != summary
            self.notificationAuthorizationState = summary
            if changed {
                self.log("local notifications \(summary)")
            }
        }
    }

    private func setAppInForeground(_ foreground: Bool) {
        guard foreground != isAppInForeground else {
            if foreground {
                adoptSystemConnectedPeripherals()
                expireStalledConnectionPhases(now: Date())
                resumeKnownPeripherals()
                reconcileDiscoveryState()
                performGrantedRuntimeMaintenance(force: true)
            } else {
                adoptSystemConnectedPeripherals()
                setFullMeshNotifications(enabled: false)
                enforceBackgroundConnectionBudget()
                resumeKnownPeripherals()
                reconcileDiscoveryState()
                flushConversationPersistence()
            }
            refreshAnnounceHeartbeat()
            refreshScanWatchdog()
            refreshConnectionDiagnostics()
            return
        }
        isAppInForeground = foreground
        liveVoiceCoordinator.setAppInForeground(foreground)
        if foreground {
            backgroundAlertState = "ready"
            backgroundDrainActive = false
            setFullMeshNotifications(enabled: true)
            adoptSystemConnectedPeripherals()
            // System-owned background connect requests can leave their slots
            // occupied long after the UI returns; free the stalled ones now
            // instead of waiting for the next watchdog pass.
            expireStalledConnectionPhases(now: Date())
            resumeKnownPeripherals()
            reconcileDiscoveryState()
            performGrantedRuntimeMaintenance(force: true)
        } else {
            // Background discovery and timely alerts share the same tiny
            // watchOS budget. Preserve two deliberately selected relays (the
            // system's background connection limit), and stop scanning so
            // advertisements cannot spend opportunities needed for messages.
            adoptSystemConnectedPeripherals()
            setFullMeshNotifications(enabled: false)
            enforceBackgroundConnectionBudget()
            resumeKnownPeripherals()
            reconcileDiscoveryState()
            flushConversationPersistence()
        }
        refreshAnnounceHeartbeat()
        refreshScanWatchdog()
        refreshConnectionDiagnostics()
    }

    private func setFullMeshNotifications(enabled: Bool) {
        var legacyLanesKept = 0
        var changedLanes = 0
        for (uuid, characteristic) in writableCharacteristics {
            guard let peripheral = peripherals[uuid],
                  peripheral.state == .connected else { continue }
            let hasAlertLane = alertCharacteristics[uuid] != nil
            let target = enabled || !WatchMeshRuntimePolicy.shouldQuietMeshLaneInBackground(
                hasAlertLane: hasAlertLane
            )
            if !enabled, !hasAlertLane {
                legacyLanesKept += 1
            }
            if requestMeshNotificationState(
                target,
                for: peripheral,
                characteristic: characteristic
            ) {
                changedLanes += 1
            }
        }
        guard changedLanes > 0 else { return }
        if enabled {
            log("foreground mesh subscriptions enabled")
        } else {
            log(
                "background alert-only subscriptions enabled"
                    + (legacyLanesKept > 0
                        ? "; kept \(legacyLanesKept) legacy mesh lane(s)"
                        : "")
            )
        }
    }

    private func desiredMeshNotificationState(for uuid: UUID) -> Bool {
        alertCharacteristics[uuid] == nil
            || isAppInForeground
            || backgroundDrainActive
    }

    /// Starts at most one Core Bluetooth subscription transition at a time.
    /// If lifecycle state changes while it is in flight, the delegate callback
    /// observes the newest desired state and immediately performs the inverse
    /// transition. This closes the wrist-down → wrist-up race where a late
    /// unsubscribe previously left the foreground lane permanently silent.
    @discardableResult
    private func requestMeshNotificationState(
        _ enabled: Bool,
        for peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> Bool {
        let uuid = peripheral.identifier
        guard peripheral.state == .connected,
              peripherals[uuid] === peripheral,
              writableCharacteristics[uuid] === characteristic else { return false }
        if meshNotificationRequests[uuid] != nil {
            return false
        }
        guard characteristic.isNotifying != enabled else { return false }
        meshNotificationRequests[uuid] = enabled
        peripheral.setNotifyValue(enabled, for: characteristic)

        let timeout = DispatchWorkItem { [weak self, weak peripheral, weak characteristic] in
            guard let self, let peripheral, let characteristic,
                  self.running,
                  self.peripherals[uuid] === peripheral,
                  self.writableCharacteristics[uuid] === characteristic,
                  self.meshNotificationRequests[uuid] == enabled else { return }
            self.meshNotificationTimeoutWorkItems.removeValue(forKey: uuid)
            self.meshNotificationRequests.removeValue(forKey: uuid)
            self.failLink(
                peripheral,
                reason: "mesh subscription transition timed out target=\(enabled)"
            )
        }
        meshNotificationTimeoutWorkItems[uuid]?.cancel()
        meshNotificationTimeoutWorkItems[uuid] = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.meshNotificationTransitionTimeout,
            execute: timeout
        )
        return true
    }

    /// watchOS supports at most two background BLE connections per app. Carry
    /// two known-good, distinct alert relays into suspension instead of letting
    /// the system choose unpredictably. Parked links are reconnected when the
    /// foreground eight-link mesh resumes.
    private func enforceBackgroundConnectionBudget() {
        guard running, !isAppInForeground, let centralManager else { return }
        // A parked link kills every fragment train flowing across it; defer
        // the budget until in-flight assemblies complete or expire.
        guard !fragmentAssembler.hasActiveAssemblies else { return }
        let candidates = peripherals.values.compactMap { peripheral -> WatchBackgroundRelayCandidate? in
            guard peripheral.state == .connected else { return nil }
            let id = peripheral.identifier
            let historicalPeerID = peripheralHistory.snapshot(for: id).peerID
            return WatchBackgroundRelayCandidate(
                id: id,
                peerID: directPeerByLink[id]?.id ?? historicalPeerID,
                supportsAlertLane: alertCharacteristics[id] != nil,
                rssi: peripheralRSSI[id] ?? -100,
                connectedAt: connectedAt[id] ?? .distantPast
            )
        }
        let keep = Set(
            WatchMeshRuntimePolicy.selectBackgroundRelays(candidates).map(\.id)
        )
        let extras = candidates.filter { !keep.contains($0.id) }
        guard !extras.isEmpty else { return }
        for candidate in extras {
            guard let peripheral = peripherals[candidate.id] else { continue }
            backgroundParkedLinks.insert(candidate.id)
            reconnectWorkItems.removeValue(forKey: candidate.id)?.cancel()
            connectionRequestedAt.removeValue(forKey: candidate.id)
            connectionPhases.removeValue(forKey: candidate.id)
            if let mesh = writableCharacteristics[candidate.id] {
                _ = requestMeshNotificationState(
                    false,
                    for: peripheral,
                    characteristic: mesh
                )
            }
            if let alert = alertCharacteristics[candidate.id], alert.isNotifying {
                peripheral.setNotifyValue(false, for: alert)
            }
            centralManager.cancelPeripheralConnection(peripheral)
        }
        log("parked \(extras.count) link(s); preserving \(keep.count) background alert relay(s)")
        refreshConnectionDiagnostics()
    }

    private func refreshScanWatchdog() {
        scanWatchdog?.cancel()
        scanWatchdog = nil
        guard running, isAppInForeground, !WatchDemoMode.isEnabled else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + WatchMeshRuntimePolicy.scanWatchdogInterval,
            repeating: WatchMeshRuntimePolicy.scanWatchdogInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.runForegroundTransportWatchdog()
        }
        scanWatchdog = timer
        timer.resume()
    }

    private func runForegroundTransportWatchdog(now: Date = Date()) {
        guard running, isAppInForeground,
              let centralManager,
              centralManager.state == .poweredOn else { return }

        expireStalledConnectionPhases(now: now)
        guard self.centralManager === centralManager else { return }
        drainDiscoveryCandidates(now: now)

        var rearmedScan = false
        if shouldKeepDiscoveryArmed,
           centralManager.isScanning,
           now.timeIntervalSince(lastDiscoveryAt)
                >= WatchMeshRuntimePolicy.foregroundScanStaleInterval {
            log("scan watchdog: rearming stale discovery")
            centralManager.stopScan()
            isScanning = false
            rearmedScan = true
        }

        if !rearmedScan,
           announcedReadyLinks.isEmpty,
           connectionPhases.isEmpty,
           now.timeIntervalSince(lastBluetoothProgressAt)
                >= WatchMeshRuntimePolicy.centralRecoveryStaleInterval {
            rebuildCentralManager(reason: "no Bluetooth progress")
            return
        }
        reconcileDiscoveryState()
    }

    private func expireStalledConnectionPhases(now: Date) {
        let expired = connectionPhases.filter {
            now.timeIntervalSince($0.value.startedAt) >= $0.value.phase.timeout
        }
        for (id, state) in expired {
            consecutivePhaseTimeouts += 1
            connectionPhases.removeValue(forKey: id)
            connectionRequestedAt.removeValue(forKey: id)
            peripheralHistory.recordFailure(id, at: now)
            phaseTimeoutCount += 1
            lastRecoveryReason = "\(state.phase.rawValue) timeout"
            log("\(state.phase.rawValue) timeout \(id.uuidString.prefix(8))")
            guard let peripheral = peripherals[id] else { continue }
            if peripheral.state == .disconnected {
                scheduleReconnect(peripheral)
            } else {
                centralManager?.cancelPeripheralConnection(peripheral)
                schedulePhaseCancellationVerification(
                    peripheral,
                    phase: state.phase
                )
            }
        }
        refreshConnectionDiagnostics()
        if consecutivePhaseTimeouts >= 3, announcedReadyLinks.isEmpty {
            rebuildCentralManager(reason: "repeated connection phase timeouts", now: now)
        }
    }

    private func schedulePhaseCancellationVerification(
        _ peripheral: CBPeripheral,
        phase: WatchConnectionPhase
    ) {
        let id = peripheral.identifier
        recoveryVerificationWorkItems.removeValue(forKey: id)?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self else { return }
            self.recoveryVerificationWorkItems.removeValue(forKey: id)
            guard let peripheral,
                  self.running,
                  self.isAppInForeground,
                  self.peripherals[id] === peripheral,
                  peripheral.state != .disconnected else { return }
            // A wedged peripheral only justifies a full central rebuild when
            // no healthy link remains; otherwise the collateral damage is
            // worse than the stuck candidate, which failure backoff already
            // starves.
            guard self.announcedReadyLinks.isEmpty else {
                self.log("keeping \(self.announcedReadyLinks.count) ready link(s); not rebuilding for wedged \(phase.rawValue)")
                return
            }
            self.rebuildCentralManager(
                reason: "uncancelled \(phase.rawValue) timeout"
            )
        }
        recoveryVerificationWorkItems[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func rebuildCentralManager(reason: String, now: Date = Date()) {
        guard running, isAppInForeground,
              now.timeIntervalSince(lastCentralRebuildAt)
                >= WatchMeshRuntimePolicy.centralRebuildMinimumInterval else { return }

        lastCentralRebuildAt = now
        lastBluetoothProgressAt = now
        recoveryCount += 1
        lastRecoveryReason = reason
        centralState = "recovering"
        log("rebuilding Bluetooth central: \(reason)")

        candidateDrainWorkItem?.cancel()
        candidateDrainWorkItem = nil
        for workItem in reconnectWorkItems.values { workItem.cancel() }
        reconnectWorkItems.removeAll()
        for workItem in recoveryVerificationWorkItems.values { workItem.cancel() }
        recoveryVerificationWorkItems.removeAll()

        let oldCentral = centralManager
        oldCentral?.delegate = nil
        oldCentral?.stopScan()
        for peripheral in peripherals.values {
            peripheral.delegate = nil
            oldCentral?.cancelPeripheralConnection(peripheral)
        }
        centralManager = nil
        clearTransportStateForCentralRebuild()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running, self.centralManager == nil else { return }
            self.makeCentralManager()
        }
    }

    private func clearTransportStateForCentralRebuild() {
        peripherals.removeAll()
        writableCharacteristics.removeAll()
        alertCharacteristics.removeAll()
        announcedReadyLinks.removeAll()
        directPeerByLink.removeAll()
        pendingWrites.removeAll()
        connectionRequestedAt.removeAll()
        connectionPhases.removeAll()
        discoveryCandidates.removeAll()
        for workItem in meshNotificationTimeoutWorkItems.values { workItem.cancel() }
        meshNotificationTimeoutWorkItems.removeAll()
        meshNotificationRequests.removeAll()
        meshNotificationFailureCounts.removeAll()
        peripheralLastDiscoveredAt.removeAll()
        peripheralRSSI.removeAll()
        connectedAt.removeAll()
        retiredDuplicateLinks.removeAll()
        consecutivePhaseTimeouts = 0
        isScanning = false
        refreshConnectionDiagnostics()
        refreshAnnounceHeartbeat()
    }

    /// Called by SwiftUI's Bluetooth-alert background task. Keep the task open
    /// until a user-visible message has been fully admitted and handed to the
    /// notification center (or a short timeout expires). A characteristic
    /// callback can contain an announce, a receipt, or only one fragment; ending
    /// the task on that first callback lets watchOS suspend us before the actual
    /// message arrives.
    ///
    /// Temporarily reopen the full-mesh lane during the granted runtime. The
    /// alert characteristic is a one-packet wake path; deferred directed
    /// packets the peer spooled flush on resubscription, and live traffic
    /// flows for the drain window — without spending further budget on
    /// gossip-sync request bursts, which stay foreground-only.
    func handleBluetoothBackgroundWake() async {
        let alertTicket = bluetoothAlertGate.arm()
        await MainActor.run {
            // A bluetoothAlert task can be delivered while the UI is active.
            // Downgrading real foreground state would silence the announce
            // heartbeat, the transport watchdog, and presence expiry while
            // the user is looking at the app. The Always-On blur state is
            // foreground for the same reason: tearing down on every wrist
            // flick reconfigures every link several times per second.
            let applicationState = WKApplication.shared().applicationState
            isAppInteractive = applicationState == .active
            if applicationState == .background {
                isAppInForeground = false
                liveVoiceCoordinator.setAppInForeground(false)
            }
            backgroundAlertState = "waiting"
            if !running { start() }
            adoptSystemConnectedPeripherals()
            enforceBackgroundConnectionBudget()
            // Hung connection attempts only time out when runtime is granted;
            // free their pending slots before issuing new requests.
            expireStalledConnectionPhases(now: Date())
            beginBackgroundDrain()
            sendBackgroundAnnounceIfDue()
        }

        async let messageCompletion: Void = bluetoothAlertGate.wait(
            alertTicket,
            timeoutNanoseconds: Self.bluetoothAlertTimeoutNanoseconds
        )
        try? await Task.sleep(
            nanoseconds: Self.bluetoothAlertMinimumDrainNanoseconds
        )
        await messageCompletion
        await waitForFragmentDrainWithinGrantedRuntime()

        let fallbackSignalID = await MainActor.run { completeBackgroundDrain() }
        await notifyCatchUpIfNeeded(fallbackSignalID)
    }

    private func beginBackgroundDrain() {
        if !backgroundDrainActive {
            backgroundDrainActive = true
            backgroundDrainStartedAt = Date()
        }
        setFullMeshNotifications(enabled: true)
        resumeKnownPeripherals()
        reconcileDiscoveryState()
    }

    private func waitForFragmentDrainWithinGrantedRuntime() async {
        while !Task.isCancelled {
            let shouldWait = await MainActor.run {
                backgroundDrainActive
                    && fragmentAssembler.hasActiveAssemblies
                    && Date().timeIntervalSince(backgroundDrainStartedAt)
                        < Self.backgroundDrainMaxSeconds
            }
            guard shouldWait else { return }
            try? await Task.sleep(
                nanoseconds: Self.backgroundDrainPollNanoseconds
            )
        }
    }

    @discardableResult
    private func completeBackgroundDrain() -> String? {
        // Another overlapping SwiftUI task still owns granted runtime and
        // will close the shared lane when its own ticket completes.
        guard bluetoothAlertGate.pendingCount == 0 else { return nil }
        backgroundDrainActive = false
        // The app may have foregrounded during the drain; only quiet the
        // lane when it is still backgrounded.
        if !isAppInForeground {
            setFullMeshNotifications(enabled: false)
            enforceBackgroundConnectionBudget()
        }
        if backgroundAlertState == "waiting" {
            backgroundAlertState = "idle"
        }
        reconcileDiscoveryState()
        flushConversationPersistence()
        let signalID = pendingTimelyAlertSignalIDs.max()
        pendingTimelyAlertSignalIDs.removeAll()
        return signalID
    }

    private func notifyCatchUpIfNeeded(_ signalID: String?) async {
        guard let signalID else { return }
        let error = await WatchNotifications.notifyCatchUpSignal(signalID)
        await MainActor.run {
            recordNotificationResult(error, messageID: "catchup-\(signalID)")
        }
    }

    /// The SwiftUI bluetoothAlert task is not the only delivery path: after
    /// a process relaunch the system can deliver the alert characteristic
    /// update straight to the delegate without ever running that task, which
    /// would leave the spooled message stuck behind a closed mesh lane. Drive
    /// the same drain directly from the callback so delivery is independent
    /// of which wake path watchOS chose.
    private func beginDelegateDrivenDrainIfNeeded() {
        guard running, !isAppInForeground, !backgroundDrainActive,
              bluetoothAlertGate.pendingCount == 0 else { return }
        beginBackgroundDrain()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.delegateDrivenDrainSeconds
        ) { [weak self] in
            guard let self,
                  self.backgroundDrainActive,
                  self.bluetoothAlertGate.pendingCount == 0 else { return }
            let signalID = self.completeBackgroundDrain()
            Task { await self.notifyCatchUpIfNeeded(signalID) }
        }
    }

    /// watchOS does not grant a continuously executing foreground service.
    /// Catch up timer-owned mesh work whenever the system grants foreground or
    /// Bluetooth-alert runtime instead of waiting for those timers to run while
    /// the process is suspended.
    private func performGrantedRuntimeMaintenance(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastGrantedRuntimeMaintenance) >= 5 else {
            return
        }
        lastGrantedRuntimeMaintenance = now
        housekeepingIfNeeded()
        guard centralManager?.state == .poweredOn,
              !writableCharacteristics.isEmpty else { return }
        sendAnnounceToAllLinks()
        requestPublicSyncIfNeeded(force: true)
        requestStalledFragments()
        for peerID in Array(pendingPrivateMediaPayloads.keys) {
            resolvePendingPrivateMedia(for: peerID)
        }
        for peerID in Array(pendingNoisePayloads.keys)
        where !noise.isEstablished(with: peerID) {
            initiateNoiseHandshake(with: peerID)
        }
    }

    /// Peers expire presence for a node that stops announcing. The announce
    /// heartbeat cannot run while suspended, so background presence refresh
    /// rides on granted Bluetooth-alert runtime, rate-limited to keep the
    /// scarce wake budget for message traffic.
    private func sendBackgroundAnnounceIfDue() {
        guard running, !isAppInForeground,
              centralManager?.state == .poweredOn,
              !writableCharacteristics.isEmpty,
              Date().timeIntervalSince(lastAnnounceSentAt)
                >= Self.backgroundAnnounceInterval else { return }
        sendAnnounceToAllLinks()
    }

    func openDirectMessage(_ peerID: PeerID) {
        activeDMPeer = peerID
        unreadDms.removeValue(forKey: peerID.id)
        sortPeers()
        WatchNotifications.clearConversation(peerID.id)
        for message in privateMessages[peerID.id] ?? []
        where !message.isSelf && message.supportsReceipts {
            sendReadReceiptIfNeeded(messageID: message.id, to: peerID)
        }
        initiateNoiseHandshake(with: peerID)
    }

    func closeDirectMessage(_ peerID: PeerID) {
        if activeDMPeer == peerID { activeDMPeer = nil }
    }

    func openPublicConversation() {
        isPublicConversationActive = true
    }

    func closePublicConversation() {
        isPublicConversationActive = false
    }

    func clearLog() {
        logLines.removeAll()
    }

    private func seedScreenshotDemo() {
        let now = Date()
        let novaID = PeerID(str: "a11ce00000000001")
        let riverID = PeerID(str: "b0b0000000000002")
        let keyA = Data(repeating: 0x11, count: 32)
        let keyB = Data(repeating: 0x22, count: 32)

        peers = [
            WatchPeer(
                peerID: novaID,
                nickname: "nova",
                noisePublicKey: keyA,
                signingPublicKey: keyA,
                lastSeen: now,
                capabilities: [.privateMedia]
            ),
            WatchPeer(
                peerID: riverID,
                nickname: "river",
                noisePublicKey: keyB,
                signingPublicKey: keyB,
                lastSeen: now.addingTimeInterval(-18),
                capabilities: [.privateMedia]
            )
        ]
        unreadDms = [novaID.id: 2]
        messages = [
            WatchChatMessage(
                id: "demo-public-1",
                sender: "nova",
                senderPeerID: novaID,
                content: "Nearby mesh is live — no internet needed.",
                timestamp: now.addingTimeInterval(-150),
                isSelf: false,
                isPrivate: false,
                conversationPeerID: nil,
                status: "",
                media: nil
            ),
            WatchChatMessage(
                id: "demo-public-2",
                sender: identity.nickname,
                senderPeerID: identity.peerID,
                content: "Hello from Apple Watch 👋",
                timestamp: now.addingTimeInterval(-92),
                isSelf: true,
                isPrivate: false,
                conversationPeerID: nil,
                status: "sent",
                media: nil
            ),
            WatchChatMessage(
                id: "demo-public-3",
                sender: "river",
                senderPeerID: riverID,
                content: "Signal looks good from here.",
                timestamp: now.addingTimeInterval(-35),
                isSelf: false,
                isPrivate: false,
                conversationPeerID: nil,
                status: "",
                media: nil
            )
        ]
        let focusImage = ProcessInfo.processInfo.arguments.contains(
            "--watch-screenshot-image"
        )
        let focusVoice = ProcessInfo.processInfo.arguments.contains(
            "--watch-screenshot-voice"
        )
        let imageMessage = makeDemoImageAttachment().map { image in
            WatchChatMessage(
                id: "demo-public-image",
                sender: "nova",
                senderPeerID: novaID,
                content: image.fileName,
                timestamp: now.addingTimeInterval(focusImage ? -6 : -18),
                isSelf: false,
                isPrivate: false,
                conversationPeerID: nil,
                status: "",
                media: image
            )
        }
        let audioMessage = makeDemoAudioAttachment().map { audio in
            WatchChatMessage(
                id: "demo-public-audio",
                sender: "river",
                senderPeerID: riverID,
                content: audio.fileName,
                timestamp: now.addingTimeInterval(focusImage ? -18 : -6),
                isSelf: false,
                isPrivate: false,
                conversationPeerID: nil,
                status: "",
                media: audio
            )
        }
        if focusImage {
            if let imageMessage { messages.append(imageMessage) }
        } else if focusVoice {
            if let audioMessage { messages.append(audioMessage) }
        } else {
            if let imageMessage { messages.append(imageMessage) }
            if let audioMessage { messages.append(audioMessage) }
        }
        privateMessages[novaID.id] = [
            WatchChatMessage(
                id: "demo-dm-1",
                sender: "nova",
                senderPeerID: novaID,
                content: "This message is Noise encrypted.",
                timestamp: now.addingTimeInterval(-70),
                isSelf: false,
                isPrivate: true,
                conversationPeerID: novaID,
                status: "",
                media: nil
            ),
            WatchChatMessage(
                id: "demo-dm-2",
                sender: identity.nickname,
                senderPeerID: identity.peerID,
                content: "Verified on my watch.",
                timestamp: now.addingTimeInterval(-26),
                isSelf: true,
                isPrivate: true,
                conversationPeerID: novaID,
                status: "read",
                media: nil
            )
        ]
        logLines = [
            "demo: mesh ready",
            "peer + nova (a11ce000)",
            "peer + river (b0b00000)",
            "noise ✓ a11ce000"
        ]
    }

    private func makeDemoImageAttachment() -> WatchMediaAttachment? {
        let width = 240
        let height = 140
        let rowStride = ((width * 3 + 3) / 4) * 4
        let pixelBytes = rowStride * height
        var bitmap = Data()
        bitmap.append(contentsOf: [0x42, 0x4D])
        bitmap.appendLittleEndian(UInt32(54 + pixelBytes))
        bitmap.appendLittleEndian(UInt32(0))
        bitmap.appendLittleEndian(UInt32(54))
        bitmap.appendLittleEndian(UInt32(40))
        bitmap.appendLittleEndian(Int32(width))
        bitmap.appendLittleEndian(Int32(height))
        bitmap.appendLittleEndian(UInt16(1))
        bitmap.appendLittleEndian(UInt16(24))
        bitmap.appendLittleEndian(UInt32(0))
        bitmap.appendLittleEndian(UInt32(pixelBytes))
        bitmap.appendLittleEndian(Int32(2_835))
        bitmap.appendLittleEndian(Int32(2_835))
        bitmap.appendLittleEndian(UInt32(0))
        bitmap.appendLittleEndian(UInt32(0))

        for y in 0..<height {
            for x in 0..<width {
                let centerX = Double(x - width / 2)
                let centerY = Double(y - height / 2)
                let ring = abs(hypot(centerX, centerY) - 43) < 4
                let risingLine = abs(y - (x * height / width)) < 3
                let fallingLine = abs(y - (height - 1 - x * height / width)) < 3

                if ring {
                    bitmap.append(contentsOf: [75, 215, 50])
                } else if risingLine || fallingLine {
                    bitmap.append(contentsOf: [10, 159, 255])
                } else {
                    let glow = UInt8(max(0, 20 - Int(hypot(centerX, centerY) / 8)))
                    bitmap.append(contentsOf: [7, 12 &+ glow, 5])
                }
            }
            bitmap.append(contentsOf: repeatElement(
                UInt8(0),
                count: rowStride - width * 3
            ))
        }

        let url = demoMediaDirectory().appendingPathComponent("mesh-preview.bmp")
        do {
            try bitmap.write(to: url, options: .atomic)
            return WatchMediaAttachment(
                url: url,
                fileName: "mesh-preview.bmp",
                mimeType: "image/bmp",
                byteCount: bitmap.count
            )
        } catch {
            return nil
        }
    }

    private func makeDemoAudioAttachment() -> WatchMediaAttachment? {
        let sampleRate = 16_000
        let duration = 6.0
        let sampleCount = Int(Double(sampleRate) * duration)
        let bytesPerSample = 2
        let audioBytes = sampleCount * bytesPerSample
        var wave = Data()
        wave.append(contentsOf: Data("RIFF".utf8))
        wave.appendLittleEndian(UInt32(36 + audioBytes))
        wave.append(contentsOf: Data("WAVEfmt ".utf8))
        wave.appendLittleEndian(UInt32(16))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt32(sampleRate))
        wave.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        wave.appendLittleEndian(UInt16(bytesPerSample))
        wave.appendLittleEndian(UInt16(16))
        wave.append(contentsOf: Data("data".utf8))
        wave.appendLittleEndian(UInt32(audioBytes))

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let envelope = min(1, time * 8) * min(1, (duration - time) * 8)
            let tone = sin(2 * .pi * 440 * time) * 0.65
                + sin(2 * .pi * 660 * time) * 0.25
            let sample = Int16(max(-1, min(1, tone * envelope)) * Double(Int16.max))
            wave.appendLittleEndian(sample)
        }

        let url = demoMediaDirectory().appendingPathComponent("voice-message.wav")
        do {
            try wave.write(to: url, options: .atomic)
            return WatchMediaAttachment(
                url: url,
                fileName: "voice-message.wav",
                mimeType: "audio/wav",
                byteCount: wave.count
            )
        } catch {
            return nil
        }
    }

    private func demoMediaDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchScreenshotDemo", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - Public state helpers

    func messages(for peerID: PeerID) -> [WatchChatMessage] {
        privateMessages[peerID.id] ?? []
    }

    func peer(_ peerID: PeerID) -> WatchPeer? {
        peers.first { $0.peerID == peerID } ?? knownPeerStore.peer(peerID)
    }

    func hasEstablishedSession(_ peerID: PeerID) -> Bool {
        if WatchDemoMode.isEnabled, peers.contains(where: { $0.peerID == peerID }) {
            return true
        }
        return noise.isEstablished(with: peerID)
    }

    func fingerprint(for peerID: PeerID) -> String? {
        noise.fingerprint(for: peerID) ?? peer(peerID).map {
            SHA256.hash(data: $0.noisePublicKey)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    func trust(for peerID: PeerID) -> WatchPeerTrust {
        trustStore.trust(for: peerID.id, fingerprint: fingerprint(for: peerID))
    }

    func toggleFavorite(_ peerID: PeerID) {
        let updated = trustStore.toggleFavorite(peerID: peerID.id)
        trustRevision &+= 1
        sendPrivateControl(
            updated.isFavorite ? "[FAVORITED]:" : "[UNFAVORITED]:",
            to: peerID
        )
        WKInterfaceDevice.current().play(.click)
    }

    func setVerified(_ verified: Bool, peerID: PeerID) {
        guard let fingerprint = fingerprint(for: peerID) else { return }
        _ = trustStore.setVerified(
            verified,
            peerID: peerID.id,
            fingerprint: fingerprint
        )
        trustRevision &+= 1
        WKInterfaceDevice.current().play(verified ? .success : .click)
    }

    // MARK: - Sending

    func sendPublicMessage(_ content: String) {
        let trimmed = Self.truncateToByteLimit(
            content.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.maxPublicContentBytes
        )
        guard !trimmed.isEmpty,
              let packet = WatchPacketFactory.publicMessagePacket(
                identity: identity,
                content: trimmed
              ) else { return }

        let messageID = WatchPacketFactory.stableMessageID(
            senderIDHex: identity.peerID.id,
            timestampMs: packet.timestamp,
            content: trimmed
        )
        messages.append(WatchChatMessage(
            id: messageID,
            sender: identity.nickname,
            senderPeerID: identity.peerID,
            content: trimmed,
            timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
            isSelf: true,
            isPrivate: false,
            conversationPeerID: nil,
            status: "sending",
            media: nil
        ))
        trimTimelineIfNeeded()
        seenMessageIDs.insert(messageID)
        let sent = broadcast(packet)
        gossipStore.record(packet)
        updatePublicStatus(
            messageID,
            status: sent > 0 ? "sent" : "waiting for peers"
        )
        log("tx public \(trimmed.utf8.count)B → \(sent) link(s)")
        WKInterfaceDevice.current().play(.click)
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        let trimmed = Self.truncateToByteLimit(
            content.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.maxPrivateContentBytes
        )
        guard !trimmed.isEmpty else { return }
        let messageID = UUID().uuidString
        let recipientName = peer(peerID)?.nickname ?? String(peerID.id.prefix(8))
        appendPrivateMessage(
            WatchChatMessage(
                id: messageID,
                sender: identity.nickname,
                senderPeerID: identity.peerID,
                content: trimmed,
                timestamp: Date(),
                isSelf: true,
                isPrivate: true,
                conversationPeerID: peerID,
                status: "sending",
                media: nil
            ),
            peerID: peerID
        )

        guard let encoded = WatchPrivateMessagePacket(
            messageID: messageID,
            content: trimmed
        ).encode() else {
            updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            return
        }
        var typed = Data([WatchNoisePayloadType.privateMessage.rawValue])
        typed.append(encoded)
        enqueueOrSendNoise(typed, messageID: messageID, to: peerID)
        log("tx DM \(trimmed.utf8.count)B → \(recipientName)")
        WKInterfaceDevice.current().play(.click)
    }

    /// Returns a fire-and-forget live sender only when the current audience
    /// can hear frames now. An unavailable DM falls back to the classic voice
    /// recorder; public mesh remains live whenever the watch node is running.
    func liveVoiceFrameSender(to peerID: PeerID?) -> ((Data) -> Void)? {
        guard running else { return nil }
        if let peerID {
            guard peer(peerID) != nil,
                  noise.isEstablished(with: peerID),
                  !writableCharacteristics.isEmpty else { return nil }
        }
        return { [weak self] payload in
            self?.sendLiveVoiceFrame(payload, to: peerID)
        }
    }

    private func sendLiveVoiceFrame(_ payload: Data, to peerID: PeerID?) {
        guard !payload.isEmpty,
              payload.count <= TransportConfig.pttMaxBurstContentBytes else {
            return
        }
        if let peerID {
            // Never queue live audio behind a handshake: by the time the
            // session establishes these frames are no longer useful.
            guard noise.isEstablished(with: peerID) else { return }
            var typed = Data([WatchNoisePayloadType.voiceFrame.rawValue])
            typed.append(payload)
            do {
                let ciphertext = try noise.encrypt(typed, for: peerID)
                _ = broadcast(
                    WatchPacketFactory.noiseEncryptedPacket(
                        identity: identity,
                        recipient: peerID,
                        ciphertext: ciphertext
                    ),
                    priority: .realtime
                )
            } catch {
                log("PTT drop: Noise unavailable for \(peerID.id.prefix(8))")
            }
        } else if let packet = WatchPacketFactory.publicVoiceFramePacket(
            identity: identity,
            payload: payload
        ) {
            _ = broadcast(packet, priority: .realtime)
        }
    }

    func sendVoiceNote(_ url: URL, to peerID: PeerID?) {
        guard let content = try? Data(contentsOf: url),
              FileTransferLimits.isValidPayload(content.count) else {
            log("voice note unavailable or too large")
            return
        }
        let file = WatchFilePacket(
            fileName: url.lastPathComponent,
            fileSize: UInt64(content.count),
            mimeType: "audio/mp4",
            content: content
        )
        let attachment = WatchMediaStore.attachment(forLocalURL: url, mimeType: "audio/mp4")

        if let peerID {
            // Derive the ID from immutable wire fields now; whether receipts
            // are enabled is decided later by exact-session peer state.
            let stableMessageID = PrivateMediaMessageIdentity.stableID(
                senderPeerID: identity.peerID,
                recipientPeerID: peerID,
                fileName: file.fileName
            )
            let messageID = stableMessageID ?? UUID().uuidString
            appendPrivateMessage(
                WatchChatMessage(
                    id: messageID,
                    sender: identity.nickname,
                    senderPeerID: identity.peerID,
                    content: attachment.fileName,
                    timestamp: Date(),
                    isSelf: true,
                    isPrivate: true,
                    conversationPeerID: peerID,
                    status: "sending",
                    media: attachment,
                    supportsReceipts: supportsPrivateMediaReceipts(with: peerID)
                ),
                peerID: peerID
            )
            guard let encoded = file.encode() else {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
                return
            }
            var typed = Data([WatchNoisePayloadType.privateFile.rawValue])
            typed.append(encoded)
            enqueueOrSendNoise(typed, messageID: messageID, to: peerID)
        } else {
            guard let packet = WatchPacketFactory.fileTransferPacket(
                identity: identity,
                file: file
            ) else { return }
            let messageID = "media-" + WatchPacketFactory.stableMessageID(
                senderIDHex: identity.peerID.id,
                timestampMs: packet.timestamp,
                content: attachment.fileName
            )
            messages.append(WatchChatMessage(
                id: messageID,
                sender: identity.nickname,
                senderPeerID: identity.peerID,
                content: attachment.fileName,
                timestamp: Date(),
                isSelf: true,
                isPrivate: false,
                conversationPeerID: nil,
                status: "sending",
                media: attachment
            ))
            trimTimelineIfNeeded()
            gossipStore.record(packet)
            let sent = broadcast(packet)
            updatePublicStatus(
                messageID,
                status: sent > 0 ? "sent" : "waiting for peers"
            )
        }
    }

    func updateNickname(_ newNickname: String) {
        let old = identity.nickname
        identity.setNickname(newNickname)
        guard identity.nickname != old else { return }
        log("nickname: \(old) → \(identity.nickname)")
        sendAnnounceToAllLinks()
    }

    // MARK: - Noise

    func initiateNoiseHandshake(with peerID: PeerID) {
        initiateNoiseHandshake(with: peerID, retryNumber: 0)
    }

    private func initiateNoiseHandshake(with peerID: PeerID, retryNumber: Int) {
        guard peerID != identity.peerID, !noise.isEstablished(with: peerID) else { return }
        let now = Date()
        if let last = lastHandshakeAttemptAt[peerID.id],
           now.timeIntervalSince(last) < 8 {
            return
        }
        lastHandshakeAttemptAt[peerID.id] = now
        do {
            if let payload = try noise.initiate(with: peerID) {
                _ = broadcast(WatchPacketFactory.noiseHandshakePacket(
                    identity: identity,
                    recipient: peerID,
                    payload: payload
                ))
                log("noise → \(peerID.id.prefix(8)) message 1")
                scheduleHandshakeRetry(
                    with: peerID,
                    attemptStartedAt: now,
                    retryNumber: retryNumber + 1
                )
            }
        } catch {
            log("noise start failed \(peerID.id.prefix(8)): \(error)")
        }
    }

    /// A handshake attempt that gets no answer otherwise waits for the
    /// peer's next announce — which can be minutes away — while DMs sit
    /// queued. Retry twice with the attempt pinned so announce-driven
    /// attempts supersede stale timers. Timers only fire at granted runtime.
    private func scheduleHandshakeRetry(
        with peerID: PeerID,
        attemptStartedAt: Date,
        retryNumber: Int
    ) {
        guard retryNumber <= 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.running,
                  !self.noise.isEstablished(with: peerID),
                  self.lastHandshakeAttemptAt[peerID.id] == attemptStartedAt else { return }
            self.initiateNoiseHandshake(with: peerID, retryNumber: retryNumber)
        }
    }

    private func handleNoiseHandshake(_ packet: BitchatPacket, from peerID: PeerID) {
        guard packet.recipientID == identity.peerIDData,
              !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else { return }
        do {
            let result = try noise.process(packet.payload, from: peerID)
            if let response = result.response {
                _ = broadcast(WatchPacketFactory.noiseHandshakePacket(
                    identity: identity,
                    recipient: peerID,
                    payload: response
                ))
            }
            if result.established {
                lastHandshakeAttemptAt.removeValue(forKey: peerID.id)
                trustRevision &+= 1
                log("noise ✓ \(peerID.id.prefix(8))")
                guard let authenticatedSession = noise.authenticatedSession(for: peerID) else {
                    noise.clear(peerID)
                    peerSecurity.clear(peerID)
                    return
                }
                if let nonce = peerSecurity.begin(
                    peerID: peerID,
                    session: authenticatedSession
                ) {
                    scheduleAuthenticatedPeerStateTimeout(
                        peerID: peerID,
                        session: authenticatedSession,
                        nonce: nonce
                    )
                }
                sendAuthenticatedPeerState(
                    to: peerID,
                    expectedSession: authenticatedSession
                )
                flushPendingNoise(to: peerID)
                drainDeferredEncrypted(from: peerID)
            }
        } catch {
            log("noise rejected \(peerID.id.prefix(8)): \(error)")
            noise.clear(peerID)
            peerSecurity.clear(peerID)
        }
    }

    private func handleNoiseEncrypted(_ packet: BitchatPacket, from peerID: PeerID) {
        guard packet.recipientID == identity.peerIDData,
              !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else { return }
        do {
            guard let decrypted = try noise.decryptWithSession(packet.payload, from: peerID) else {
                if deferredEncryptedPackets[peerID, default: []].count < 4 {
                    deferredEncryptedPackets[peerID, default: []].append(packet)
                }
                return
            }
            let plaintext = decrypted.plaintext
            guard let rawType = plaintext.first,
                  let type = WatchNoisePayloadType(rawValue: rawType) else { return }
            let payload = Data(plaintext.dropFirst())
            let timestamp = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
            touch(peerID)

            switch type {
            case .privateMessage:
                handlePrivateMessagePayload(payload, from: peerID, timestamp: timestamp)
            case .delivered:
                guard payload.count <= 128,
                      let messageID = String(data: payload, encoding: .utf8) else { return }
                updatePrivateStatus(messageID, peerID: peerID, status: "delivered")
                cancelPrivateMediaRetry(messageID)
            case .readReceipt:
                guard payload.count <= 128,
                      let messageID = String(data: payload, encoding: .utf8) else { return }
                updatePrivateStatus(messageID, peerID: peerID, status: "read")
                cancelPrivateMediaRetry(messageID)
            case .privateFile:
                handleFilePayload(payload, from: peerID, timestamp: timestamp, isPrivate: true)
            case .authenticatedPeerState:
                handleAuthenticatedPeerState(
                    payload,
                    from: peerID,
                    decryptedSession: decrypted.session
                )
            case .voiceFrame:
                guard payload.count <= TransportConfig.pttMaxBurstContentBytes else {
                    return
                }
                liveVoiceCoordinator.handle(
                    payload,
                    from: peerID,
                    scope: .directMessage,
                    nickname: peer(peerID)?.nickname ?? String(peerID.id.prefix(8)),
                    timestamp: timestamp
                )
            }
        } catch {
            log("noise decrypt failed \(peerID.id.prefix(8)): \(error)")
            noise.clear(peerID)
            peerSecurity.clear(peerID)
            initiateNoiseHandshake(with: peerID)
        }
    }

    private func sendAuthenticatedPeerState(
        to peerID: PeerID,
        expectedSession: WatchAuthenticatedNoiseSession
    ) {
        let state = WatchAuthenticatedPeerStatePacket(
            capabilities: WatchPacketFactory.localCapabilities,
            signingPublicKey: identity.signingPublicKeyData
        )
        guard let encoded = state.encode() else { return }
        var payload = Data([WatchNoisePayloadType.authenticatedPeerState.rawValue])
        payload.append(encoded)
        sendNoisePayload(
            payload,
            messageID: nil,
            to: peerID,
            expectedSession: expectedSession
        )
    }

    private func handleAuthenticatedPeerState(
        _ payload: Data,
        from peerID: PeerID,
        decryptedSession: WatchAuthenticatedNoiseSession
    ) {
        guard let state = WatchAuthenticatedPeerStatePacket.decode(payload) else {
            log("rejected authenticated state from \(peerID.id.prefix(8))")
            return
        }
        let receipt = peerSecurity.receive(
            peerID: peerID,
            state: state,
            decryptedSession: decryptedSession
        )
        guard receipt.accepted else {
            log("rejected unbound authenticated state from \(peerID.id.prefix(8))")
            return
        }
        applyAuthenticatedPeerState(state, from: peerID)
        if receipt.shouldEcho {
            sendAuthenticatedPeerState(
                to: peerID,
                expectedSession: decryptedSession
            )
        }
        resolvePendingPrivateMedia(for: peerID)
    }

    private func scheduleAuthenticatedPeerStateTimeout(
        peerID: PeerID,
        session: WatchAuthenticatedNoiseSession,
        nonce: UUID
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  self.noise.authenticatedSession(for: peerID) == session,
                  self.peerSecurity.expire(
                    peerID: peerID,
                    session: session,
                    nonce: nonce
                  ) else { return }
            self.log("authenticated state timed out for \(peerID.id.prefix(8))")
            self.resolvePendingPrivateMedia(for: peerID)
        }
    }

    private func applyAuthenticatedPeerState(
        _ state: WatchAuthenticatedPeerStatePacket,
        from peerID: PeerID
    ) {
        if let pending = pendingAnnouncements[peerID],
           pending.announcement.signingPublicKey == state.signingPublicKey {
            pendingAnnouncements.removeValue(forKey: peerID)
            relayIfNeeded(pending.packet, arrivedFrom: pending.linkUUID)
            applyAnnouncement(
                pending.announcement,
                packet: pending.packet,
                from: peerID,
                linkUUID: pending.linkUUID,
                authenticatedCapabilities: state.capabilities
            )
            return
        }
        if let index = peers.firstIndex(where: { $0.peerID == peerID }) {
            if peers[index].signingPublicKey != state.signingPublicKey {
                peers[index].nickname = String(peerID.id.prefix(8))
            }
            peers[index].signingPublicKey = state.signingPublicKey
            peers[index].capabilities = state.capabilities
            peers[index].lastSeen = Date()
            knownPeerStore.remember(peers[index])
            sortPeers()
        }
    }

    private func drainDeferredEncrypted(from peerID: PeerID) {
        let packets = deferredEncryptedPackets.removeValue(forKey: peerID) ?? []
        for packet in packets {
            handleNoiseEncrypted(packet, from: peerID)
        }
    }

    private func handlePrivateMessagePayload(
        _ payload: Data,
        from peerID: PeerID,
        timestamp: Date
    ) {
        guard let privateMessage = WatchPrivateMessagePacket.decode(payload),
              !seenMessageIDs.contains(privateMessage.messageID) else { return }
        seenMessageIDs.insert(privateMessage.messageID)

        if WatchFavoriteControl.parse(privateMessage.content) == .favorited {
            _ = trustStore.setTheyFavoritedUs(true, peerID: peerID.id)
            trustRevision &+= 1
            return
        }
        if WatchFavoriteControl.parse(privateMessage.content) == .unfavorited {
            _ = trustStore.setTheyFavoritedUs(false, peerID: peerID.id)
            trustRevision &+= 1
            return
        }

        let nickname = peer(peerID)?.nickname ?? String(peerID.id.prefix(8))
        appendPrivateMessage(
            WatchChatMessage(
                id: privateMessage.messageID,
                sender: nickname,
                senderPeerID: peerID,
                content: privateMessage.content,
                timestamp: timestamp,
                isSelf: false,
                isPrivate: true,
                conversationPeerID: peerID,
                status: "",
                media: nil
            ),
            peerID: peerID
        )
        didReceiveDirectMessage(
            id: privateMessage.messageID,
            from: peerID,
            sender: nickname,
            preview: privateMessage.content
        )
    }

    private func enqueueOrSendNoise(
        _ payload: Data,
        messageID: String?,
        to peerID: PeerID
    ) {
        if payload.first == WatchNoisePayloadType.privateFile.rawValue {
            enqueueOrSendPrivateMedia(
                PendingNoisePayload(data: payload, messageID: messageID),
                to: peerID
            )
            return
        }
        if noise.isEstablished(with: peerID) {
            sendNoisePayload(payload, messageID: messageID, to: peerID)
            return
        }
        guard queuePendingNoisePayload(
            PendingNoisePayload(data: payload, messageID: messageID),
            for: peerID
        ) else {
            if let messageID {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
            return
        }
        initiateNoiseHandshake(with: peerID)
        if let messageID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self,
                      self.pendingNoisePayloads[peerID]?.contains(
                        where: { $0.messageID == messageID }
                      ) == true else { return }
                self.pendingNoisePayloads[peerID]?.removeAll {
                    $0.messageID == messageID
                }
                self.updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
        }
    }

    private func sendNoisePayload(
        _ payload: Data,
        messageID: String?,
        to peerID: PeerID,
        expectedSession: WatchAuthenticatedNoiseSession? = nil
    ) {
        do {
            let ciphertext: Data
            if let expectedSession {
                ciphertext = try noise.encrypt(
                    payload,
                    for: peerID,
                    expectedSession: expectedSession
                )
            } else {
                ciphertext = try noise.encrypt(payload, for: peerID)
            }
            let sent = broadcast(WatchPacketFactory.noiseEncryptedPacket(
                identity: identity,
                recipient: peerID,
                ciphertext: ciphertext
            ))
            if let messageID {
                updatePrivateStatus(
                    messageID,
                    peerID: peerID,
                    status: sent > 0 ? "sent" : "waiting for peers"
                )
            }
        } catch {
            let item = PendingNoisePayload(data: payload, messageID: messageID)
            let queued: Bool
            if payload.first == WatchNoisePayloadType.privateFile.rawValue {
                queued = queuePendingPrivateMediaPayload(item, for: peerID)
            } else {
                queued = queuePendingNoisePayload(item, for: peerID)
            }
            if !queued, let messageID {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
            noise.clear(peerID)
            peerSecurity.clear(peerID)
            initiateNoiseHandshake(with: peerID)
        }
    }

    private func enqueueOrSendPrivateMedia(
        _ item: PendingNoisePayload,
        to peerID: PeerID
    ) {
        let authenticated = noise.authenticatedSession(for: peerID)
        switch peerSecurity.sendPolicy(
            peerID: peerID,
            authenticatedSession: authenticated
        ) {
        case let .encrypted(session, supportsReceipts, _):
            if let messageID = item.messageID {
                setPrivateMediaReceiptSupport(
                    supportsReceipts,
                    messageID: messageID,
                    peerID: peerID
                )
            }
            sendNoisePayload(
                item.data,
                messageID: item.messageID,
                to: peerID,
                expectedSession: session
            )
            if supportsReceipts, let messageID = item.messageID {
                schedulePrivateMediaRetry(
                    item,
                    messageID: messageID,
                    peerID: peerID
                )
            }

        case .needsHandshake, .awaitingPeerState:
            guard queuePendingPrivateMediaPayload(item, for: peerID) else {
                if let messageID = item.messageID {
                    updatePrivateStatus(messageID, peerID: peerID, status: "failed")
                }
                return
            }
            initiateNoiseHandshake(with: peerID)

        case .legacyFallback:
            sendSignedLegacyPrivateFile(item.data, messageID: item.messageID, to: peerID)

        case .blocked:
            if let messageID = item.messageID {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
            log("private media blocked after a proven capability downgrade")
        }
    }

    /// Compatibility-only fallback for peers that have not advertised
    /// encrypted private media — mirrors iOS sendSignedLegacyPrivateFile.
    /// The payload is authenticated but visible to relays.
    private func sendSignedLegacyPrivateFile(
        _ typedPayload: Data,
        messageID: String?,
        to peerID: PeerID
    ) {
        guard typedPayload.first == WatchNoisePayloadType.privateFile.rawValue,
              let recipientData = peerID.routingData else {
            if let messageID {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
            return
        }
        let unsigned = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: identity.peerIDData,
            recipientID: recipientData,
            timestamp: WatchPacketFactory.nowMilliseconds(),
            payload: Data(typedPayload.dropFirst()),
            signature: nil,
            ttl: WatchPacketFactory.messageTTL,
            version: 2
        )
        guard let signed = WatchPacketFactory.sign(unsigned, with: identity) else {
            if let messageID {
                updatePrivateStatus(messageID, peerID: peerID, status: "failed")
            }
            return
        }
        let sent = broadcast(signed)
        if let messageID {
            updatePrivateStatus(
                messageID,
                peerID: peerID,
                status: sent > 0 ? "sent" : "waiting for peers"
            )
        }
        log("tx legacy DM media \(signed.payload.count)B → \(peerID.id.prefix(8))")
    }

    private func queuePendingPrivateMediaPayload(
        _ payload: PendingNoisePayload,
        for peerID: PeerID
    ) -> Bool {
        var pending = pendingPrivateMediaPayloads[peerID] ?? []
        guard pending.count < Self.maxPendingNoisePayloadsPerPeer else {
            log("private media queue full for \(peerID.id.prefix(8))")
            return false
        }
        if let messageID = payload.messageID,
           pending.contains(where: { $0.messageID == messageID }) {
            return true
        }
        pending.append(payload)
        pendingPrivateMediaPayloads[peerID] = pending
        return true
    }

    private func resolvePendingPrivateMedia(for peerID: PeerID) {
        guard pendingPrivateMediaPayloads[peerID]?.isEmpty == false else { return }
        let policy = peerSecurity.sendPolicy(
            peerID: peerID,
            authenticatedSession: noise.authenticatedSession(for: peerID)
        )
        switch policy {
        case let .encrypted(session, supportsReceipts, _):
            let pending = pendingPrivateMediaPayloads.removeValue(forKey: peerID) ?? []
            for item in pending {
                if let messageID = item.messageID {
                    setPrivateMediaReceiptSupport(
                        supportsReceipts,
                        messageID: messageID,
                        peerID: peerID
                    )
                }
                sendNoisePayload(
                    item.data,
                    messageID: item.messageID,
                    to: peerID,
                    expectedSession: session
                )
                if supportsReceipts, let messageID = item.messageID {
                    schedulePrivateMediaRetry(
                        item,
                        messageID: messageID,
                        peerID: peerID
                    )
                }
            }
        case .blocked:
            let pending = pendingPrivateMediaPayloads.removeValue(forKey: peerID) ?? []
            for item in pending {
                if let messageID = item.messageID {
                    updatePrivateStatus(messageID, peerID: peerID, status: "failed")
                }
            }
        case .legacyFallback:
            let pending = pendingPrivateMediaPayloads.removeValue(forKey: peerID) ?? []
            for item in pending {
                sendSignedLegacyPrivateFile(
                    item.data,
                    messageID: item.messageID,
                    to: peerID
                )
            }
        case .needsHandshake:
            initiateNoiseHandshake(with: peerID)
        case .awaitingPeerState:
            break
        }
    }

    private func supportsPrivateMediaReceipts(with peerID: PeerID) -> Bool {
        guard let session = noise.authenticatedSession(for: peerID),
              let state = peerSecurity.provenState(peerID: peerID, session: session) else {
            return false
        }
        return state.capabilities.contains(.privateMedia)
            && state.capabilities.contains(.privateMediaReceipts)
    }

    private func setPrivateMediaReceiptSupport(
        _ supported: Bool,
        messageID: String,
        peerID: PeerID
    ) {
        guard var thread = privateMessages[peerID.id],
              let index = thread.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        thread[index].supportsReceipts = supported
        privateMessages[peerID.id] = thread
    }

    private func schedulePrivateMediaRetry(
        _ item: PendingNoisePayload,
        messageID: String,
        peerID: PeerID
    ) {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else { return }
        privateMediaRetryPayloads[messageID] = (peerID, item.data)
        guard privateMediaRetryWorkItems[messageID] == nil else { return }
        let attempt = privateMediaRetryAttempts[messageID, default: 0]
        let delays: [TimeInterval] = [8, 20, 45]
        guard attempt < delays.count else {
            privateMediaRetryPayloads.removeValue(forKey: messageID)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.privateMediaRetryWorkItems.removeValue(forKey: messageID)
            guard let retry = self.privateMediaRetryPayloads[messageID],
                  let message = self.privateMessages[retry.peerID.id]?.first(
                    where: { $0.id == messageID }
                  ),
                  message.status != "delivered",
                  message.status != "read" else {
                self.cancelPrivateMediaRetry(messageID)
                return
            }
            let policy = self.peerSecurity.sendPolicy(
                peerID: retry.peerID,
                authenticatedSession: self.noise.authenticatedSession(
                    for: retry.peerID
                )
            )
            guard case let .encrypted(session, supportsReceipts, _) = policy,
                  supportsReceipts else {
                // The durable pending queue owns the payload from here. Drop
                // the retry ledger so a capability/session transition cannot
                // retain a second stale copy indefinitely.
                self.cancelPrivateMediaRetry(messageID)
                self.enqueueOrSendPrivateMedia(
                    PendingNoisePayload(data: retry.data, messageID: messageID),
                    to: retry.peerID
                )
                return
            }
            self.privateMediaRetryAttempts[messageID, default: 0] += 1
            self.sendNoisePayload(
                retry.data,
                messageID: messageID,
                to: retry.peerID,
                expectedSession: session
            )
            self.schedulePrivateMediaRetry(
                PendingNoisePayload(data: retry.data, messageID: messageID),
                messageID: messageID,
                peerID: retry.peerID
            )
        }
        privateMediaRetryWorkItems[messageID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delays[attempt],
            execute: workItem
        )
    }

    private func cancelPrivateMediaRetry(_ messageID: String) {
        privateMediaRetryWorkItems.removeValue(forKey: messageID)?.cancel()
        privateMediaRetryPayloads.removeValue(forKey: messageID)
        privateMediaRetryAttempts.removeValue(forKey: messageID)
    }

    private func restorePendingPrivateMediaRetries() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for (peerIDString, thread) in privateMessages {
            let peerID = PeerID(str: peerIDString)
            for message in thread where message.isSelf
                    && message.timestamp >= cutoff
                    && PrivateMediaMessageIdentity.isStableID(message.id)
                    && message.status != "failed"
                    && message.status != "delivered"
                    && message.status != "read" {
                guard let attachment = message.media,
                      let content = try? Data(contentsOf: attachment.url),
                      FileTransferLimits.isValidPayload(content.count) else { continue }
                let file = WatchFilePacket(
                    fileName: attachment.fileName,
                    fileSize: UInt64(content.count),
                    mimeType: attachment.mimeType,
                    content: content
                )
                guard PrivateMediaMessageIdentity.stableID(
                    senderPeerID: identity.peerID,
                    recipientPeerID: peerID,
                    fileName: file.fileName
                ) == message.id, let encoded = file.encode() else { continue }
                var typed = Data([WatchNoisePayloadType.privateFile.rawValue])
                typed.append(encoded)
                _ = queuePendingPrivateMediaPayload(
                    PendingNoisePayload(data: typed, messageID: message.id),
                    for: peerID
                )
            }
        }
    }

    private func queuePendingNoisePayload(
        _ payload: PendingNoisePayload,
        for peerID: PeerID
    ) -> Bool {
        var pending = pendingNoisePayloads[peerID] ?? []
        guard pending.count < Self.maxPendingNoisePayloadsPerPeer else {
            log("noise queue full for \(peerID.id.prefix(8))")
            return false
        }
        pending.append(payload)
        pendingNoisePayloads[peerID] = pending
        return true
    }

    private func flushPendingNoise(to peerID: PeerID) {
        let pending = pendingNoisePayloads.removeValue(forKey: peerID) ?? []
        for item in pending {
            sendNoisePayload(item.data, messageID: item.messageID, to: peerID)
        }
    }

    private func sendReceipt(
        type: WatchNoisePayloadType,
        messageID: String,
        to peerID: PeerID
    ) {
        var payload = Data([type.rawValue])
        payload.append(Data(messageID.utf8))
        enqueueOrSendNoise(payload, messageID: nil, to: peerID)
    }

    private func sendPrivateControl(_ content: String, to peerID: PeerID) {
        guard let encoded = WatchPrivateMessagePacket(
            messageID: UUID().uuidString,
            content: content
        ).encode() else { return }
        var payload = Data([WatchNoisePayloadType.privateMessage.rawValue])
        payload.append(encoded)
        enqueueOrSendNoise(payload, messageID: nil, to: peerID)
    }

    // MARK: - Announce and receive

    private func sendAnnounce(to peripheralUUIDs: [UUID]? = nil) {
        let directNeighbors = currentDirectNeighbors()
        guard let packet = WatchPacketFactory.announcePacket(
            identity: identity,
            directNeighbors: directNeighbors.compactMap(\.routingData)
        ) else { return }
        gossipStore.record(packet)
        let targets = peripheralUUIDs ?? Array(writableCharacteristics.keys)
        let sent = transmit(packet, to: targets)
        if sent > 0 {
            lastAnnounceSentAt = Date()
            log(
                "tx announce (\(identity.nickname), \(directNeighbors.count) neighbor(s)) "
                    + "→ \(sent) link(s)"
            )
        }
    }

    private func sendAnnounceToAllLinks() {
        sendAnnounce(to: nil)
    }

    private func currentDirectNeighbors() -> [PeerID] {
        let active = directPeerByLink.compactMap { linkUUID, peerID in
            writableCharacteristics[linkUUID] == nil ? nil : peerID
        }
        return Array(
            Set(active)
                .sorted { $0.id < $1.id }
                .prefix(Self.maxAnnouncedDirectNeighbors)
        )
    }

    /// A max-TTL announce that survives identity and signature verification
    /// originated on this GATT link. Relayed announces have a decremented TTL
    /// and must never be published as direct watch neighbors.
    @discardableResult
    private func observeDirectPeer(
        _ peerID: PeerID,
        on linkUUID: UUID,
        packetTTL: UInt8
    ) -> Bool {
        guard packetTTL == WatchPacketFactory.messageTTL else { return false }
        let previous = directPeerByLink.updateValue(peerID, forKey: linkUUID)
        peripheralHistory.recordAuthenticatedPeer(peerID, for: linkUUID)
        retireDuplicateDirectLinks(for: peerID)
        refreshConnectionDiagnostics()
        return previous != peerID
    }

    private func retireDuplicateDirectLinks(for peerID: PeerID) {
        let matchingLinks = directPeerByLink.compactMap { linkID, observedPeer in
            observedPeer == peerID ? linkID : nil
        }
        guard matchingLinks.count > 1 else { return }

        guard let winner = matchingLinks.sorted(by: { left, right in
            let leftReady = announcedReadyLinks.contains(left)
            let rightReady = announcedReadyLinks.contains(right)
            if leftReady != rightReady { return leftReady }
            let leftRSSI = peripheralRSSI[left] ?? Int.min
            let rightRSSI = peripheralRSSI[right] ?? Int.min
            if leftRSSI != rightRSSI { return leftRSSI > rightRSSI }
            return connectedAt[left, default: .distantFuture]
                < connectedAt[right, default: .distantFuture]
        }).first else { return }

        for linkID in matchingLinks where linkID != winner {
            guard let peripheral = peripherals[linkID] else { continue }
            retiredDuplicateLinks.insert(linkID)
            directPeerByLink.removeValue(forKey: linkID)
            connectionRequestedAt.removeValue(forKey: linkID)
            connectionPhases.removeValue(forKey: linkID)
            log("retiring duplicate peer link \(linkID.uuidString.prefix(8))")
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    @discardableResult
    private func removeDirectPeer(on linkUUID: UUID) -> Bool {
        let before = Set(currentDirectNeighbors())
        directPeerByLink.removeValue(forKey: linkUUID)
        refreshConnectionDiagnostics()
        return Set(currentDirectNeighbors()) != before
    }

    private func refreshAnnounceHeartbeat() {
        announceHeartbeat?.cancel()
        announceHeartbeat = nil
        guard running, isAppInForeground, !WatchDemoMode.isEnabled,
              centralManager?.state == .poweredOn,
              !writableCharacteristics.isEmpty else { return }

        let interval = Self.foregroundAnnounceInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.running,
                  self.centralManager?.state == .poweredOn,
                  !self.writableCharacteristics.isEmpty,
                  Date().timeIntervalSince(self.lastAnnounceSentAt) >= interval else {
                return
            }
            self.sendAnnounceToAllLinks()
            self.requestPublicSyncIfNeeded()
        }
        announceHeartbeat = timer
        timer.resume()
    }

    private func handleIncomingData(_ data: Data, from linkUUID: UUID) {
        housekeepingIfNeeded()
        let hash = Self.packetDigest(data)
        guard seenPacketHashes[hash] == nil else { return }

        guard let packet = BitchatPacket.from(data) else {
            log("rx undecodable (\(data.count)B)")
            return
        }
        let senderPeer = PeerID(hexData: packet.senderID)
        guard senderPeer != identity.peerID else {
            log("rx rejected 0x\(String(packet.type, radix: 16)): self echo")
            return
        }
        if let reason = admissionFailure(for: packet, from: senderPeer) {
            log(
                "rx rejected 0x\(String(packet.type, radix: 16)) "
                    + "\(senderPeer.id.prefix(8)): \(reason)"
            )
            return
        }

        seenPacketHashes[hash] = Date()
        if isSafeToRelay(packet, from: senderPeer) {
            relayIfNeeded(packet, arrivedFrom: linkUUID)
        }
        if isForLocalDelivery(packet) {
            process(packet, from: senderPeer, linkUUID: linkUUID)
        }
    }

    /// Returns nil when the packet may be relayed or delivered, otherwise a
    /// short human-readable rejection reason for the mesh log.
    private func admissionFailure(
        for packet: BitchatPacket,
        from senderPeer: PeerID
    ) -> String? {
        guard let type = MessageType(rawValue: packet.type) else { return "unknown type" }
        switch type {
        case .announce:
            guard let announcement = WatchAnnouncementPacket.decode(from: packet.payload) else {
                return "malformed announce"
            }
            guard PeerID(publicKey: announcement.noisePublicKey) == senderPeer else {
                return "announce identity mismatch"
            }
            guard !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else {
                return "stale announce"
            }
            guard WatchPacketFactory.verify(
                packet,
                signingPublicKey: announcement.signingPublicKey
            ) else { return "bad announce signature" }
            return nil

        case .announceV2:
            // The rotation-preserving presence format is not consumed by the
            // shipping mesh yet. Admit only a well-formed, current packet so
            // it can relay through the watch without populating local peers.
            if WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) {
                return "stale announceV2"
            }
            return AnnounceV2Packet.decode(from: packet.payload) != nil
                ? nil : "malformed announceV2"

        case .message:
            guard !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else {
                return "stale message"
            }
            guard packet.payload.count <= Self.maxPublicContentBytes else {
                return "oversized message"
            }
            guard let content = String(data: packet.payload, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "empty message"
            }
            return publicPacketFailure(packet, from: senderPeer)

        case .fileTransfer, .leave:
            if WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) {
                return type == .fileTransfer ? "stale file" : "stale leave"
            }
            return publicPacketFailure(packet, from: senderPeer)

        case .voiceFrame:
            guard packet.payload.count <= TransportConfig.pttMaxBurstContentBytes else {
                return "oversized voice frame"
            }
            return publicPacketFailure(packet, from: senderPeer)

        case .requestSync:
            guard packet.ttl == 0 else { return "routed sync request" }
            guard !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else {
                return "stale sync request"
            }
            return publicPacketFailure(packet, from: senderPeer)

        case .fragment:
            if WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) {
                return "stale fragment"
            }
            return WatchFragmentHeader(packet: packet) != nil
                ? nil : "malformed fragment header"

        case .noiseHandshake, .noiseEncrypted:
            guard !packet.payload.isEmpty else { return "empty noise payload" }
            guard packet.recipientID != nil else { return "undirected noise" }
            guard packet.recipientID != WatchPacketFactory.broadcastRecipient else {
                return "broadcast noise"
            }
            guard !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else {
                return "stale noise"
            }
            return nil

        case .ping, .pong, .boardPost, .prekeyBundle, .groupMessage,
             .courierEnvelope, .nostrCarrier:
            // Match Android's relay admission for packet families whose own
            // handlers provide their authentication. The watch does not mutate
            // local state for these types.
            return packet.payload.isEmpty ? "empty payload" : nil
        }
    }

    /// A valid self-signed announcement may still contain an unproven Ed key
    /// rotation. Deliver it locally so the Noise-bound state exchange can
    /// authenticate the replacement, but do not amplify it across the mesh
    /// until that proof succeeds.
    private func isSafeToRelay(_ packet: BitchatPacket, from senderPeer: PeerID) -> Bool {
        guard packet.type == MessageType.announce.rawValue,
              let announcement = WatchAnnouncementPacket.decode(from: packet.payload) else {
            return true
        }
        return peerSecurity.permitsAnnouncementRelay(
            noisePublicKey: announcement.noisePublicKey,
            announcedSigningKey: announcement.signingPublicKey,
            currentSigningKey: peer(senderPeer)?.signingPublicKey
        )
    }

    private func publicPacketFailure(
        _ packet: BitchatPacket,
        from senderPeer: PeerID
    ) -> String? {
        guard let knownPeer = peer(senderPeer) else { return "unknown peer" }
        return WatchPacketFactory.verify(
            packet,
            signingPublicKey: knownPeer.signingPublicKey
        ) ? nil : "bad signature"
    }

    private func process(_ packet: BitchatPacket, from senderPeer: PeerID, linkUUID: UUID) {
        guard let type = MessageType(rawValue: packet.type) else { return }
        if type != .announce { touch(senderPeer) }
        switch type {
        case .announce:
            handleAnnounce(packet, from: senderPeer, linkUUID: linkUUID)
        case .announceV2:
            // Match the phone: the format is defined, but consuming rotating
            // peer presence awaits the identity-binding policy.
            break
        case .message:
            handlePublicMessage(packet, from: senderPeer)
        case .leave:
            handleLeave(packet, from: senderPeer)
        case .fragment:
            handleFragment(packet, from: senderPeer, linkUUID: linkUUID)
        case .noiseHandshake:
            handleNoiseHandshake(packet, from: senderPeer)
        case .noiseEncrypted:
            handleNoiseEncrypted(packet, from: senderPeer)
        case .fileTransfer:
            handleFileTransfer(packet, from: senderPeer)
        case .voiceFrame:
            handlePublicVoiceFrame(packet, from: senderPeer)
        case .requestSync:
            handleRequestSync(packet, from: senderPeer, linkUUID: linkUUID)
        case .ping, .pong, .boardPost, .prekeyBundle,
             .groupMessage, .courierEnvelope, .nostrCarrier:
            break
        }
    }

    private func handleRequestSync(
        _ packet: BitchatPacket,
        from senderPeer: PeerID,
        linkUUID: UUID
    ) {
        guard let request = WatchSyncRequest.decode(packet.payload),
              shouldRespondToSync(from: senderPeer) else { return }
        let responses = gossipStore.missingPackets(
            for: request,
            nowMilliseconds: WatchPacketFactory.nowMilliseconds()
        )
        for response in responses {
            _ = transmit(response, to: [linkUUID])
        }
        if !responses.isEmpty {
            log("sync response \(responses.count) packet(s) → \(senderPeer.id.prefix(8))")
        }
    }

    private func shouldRespondToSync(from peerID: PeerID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-30)
        var recent = (syncResponseTimes[peerID] ?? []).filter { $0 >= cutoff }
        guard recent.count < 8 else {
            syncResponseTimes[peerID] = recent
            return false
        }
        recent.append(now)
        syncResponseTimes[peerID] = recent
        return true
    }

    private func requestPublicSyncIfNeeded(
        on linkUUID: UUID? = nil,
        force: Bool = false
    ) {
        // Gossip sync is a foreground activity. Every request triggers a
        // response burst, and wrist-down each burst packet spends the same
        // scarce background-notification budget that message wakes depend
        // on. Directed traffic the peer spooled flushes on resubscription
        // without a request, and public catch-up happens on foreground
        // return via performGrantedRuntimeMaintenance.
        guard isAppInForeground else { return }
        let now = Date()
        if let linkUUID {
            guard force || now.timeIntervalSince(lastPublicSyncByLink[linkUUID] ?? .distantPast) >= 15 else {
                return
            }
            lastPublicSyncByLink[linkUUID] = now
        } else {
            guard force || now.timeIntervalSince(lastPublicSyncAt) >= 15 else { return }
            lastPublicSyncAt = now
        }
        let nowMs = WatchPacketFactory.nowMilliseconds()
        // Match the admission staleness window (900 s): packets older than
        // this would be rejected on arrival, so asking servers to skip them
        // ends the perpetual stale-response flood.
        let payload = WatchSyncRequest.publicPayload(
            candidates: gossipStore.publicSyncCandidates(nowMilliseconds: nowMs),
            minimumTimestamp: nowMs > 900_000 ? nowMs - 900_000 : nil
        )
        guard let request = WatchPacketFactory.requestSyncPacket(
            identity: identity,
            payload: payload
        ) else { return }
        let targets = linkUUID.map { [$0] } ?? Array(writableCharacteristics.keys)
        let sent = transmit(request, to: targets)
        if sent > 0 { log("public sync request → \(sent) link(s)") }
    }

    private func handleAnnounce(_ packet: BitchatPacket, from senderPeer: PeerID, linkUUID: UUID) {
        guard let announcement = WatchAnnouncementPacket.decode(from: packet.payload) else {
            log("rx malformed announce from \(senderPeer.id.prefix(8))")
            return
        }
        guard PeerID(publicKey: announcement.noisePublicKey) == senderPeer,
              !WatchPacketFactory.isStale(timestampMilliseconds: packet.timestamp) else {
            return
        }

        let existing = peer(senderPeer)
        guard WatchPacketFactory.verify(
            packet,
            signingPublicKey: announcement.signingPublicKey
        ) else {
            log("rejected unsigned announce from \(senderPeer.id.prefix(8))")
            return
        }
        let persistedKey = peerSecurity.persistedSigningKey(
            for: announcement.noisePublicKey
        )
        let provenKey = noise.authenticatedSession(for: senderPeer).flatMap {
            peerSecurity.provenState(peerID: senderPeer, session: $0)?.signingPublicKey
        }
        let trustedKey = provenKey ?? persistedKey ?? existing?.signingPublicKey
        if let trustedKey, trustedKey != announcement.signingPublicKey {
            // A self-signed announce cannot rotate the Ed key by itself: park
            // it until authenticated peer state from this Noise identity proves
            // the replacement and has been persisted.
            pendingAnnouncements[senderPeer] = PendingAnnouncement(
                packet: packet,
                announcement: announcement,
                linkUUID: linkUUID
            )
            log("announce key change awaiting authenticated proof")
            initiateNoiseHandshake(with: senderPeer)
            return
        }
        applyAnnouncement(
            announcement,
            packet: packet,
            from: senderPeer,
            linkUUID: linkUUID,
            authenticatedCapabilities: nil
        )
    }

    private func applyAnnouncement(
        _ announcement: WatchAnnouncementPacket,
        packet: BitchatPacket,
        from senderPeer: PeerID,
        linkUUID: UUID,
        authenticatedCapabilities: PeerCapabilities?
    ) {
        let existing = peer(senderPeer)
        let directAssociationChanged = observeDirectPeer(
            senderPeer,
            on: linkUUID,
            packetTTL: packet.ttl
        )
        let isDirectAnnounce = packet.ttl == WatchPacketFactory.messageTTL
        let isNew = existing == nil
        let nicknameChanged = existing?.nickname != announcement.nickname
        let entry = WatchPeer(
            peerID: senderPeer,
            nickname: String(
                announcement.nickname.precomposedStringWithCanonicalMapping.prefix(32)
            ),
            noisePublicKey: announcement.noisePublicKey,
            signingPublicKey: announcement.signingPublicKey,
            lastSeen: Date(),
            capabilities: authenticatedCapabilities
                ?? announcement.capabilities
                ?? existing?.capabilities
                ?? []
        )
        if let index = peers.firstIndex(where: { $0.peerID == senderPeer }) {
            peers[index] = entry
        } else {
            evictOldestPeerIfNeeded()
            peers.append(entry)
        }
        knownPeerStore.remember(entry)
        gossipStore.record(packet)
        sortPeers()

        if isNew {
            log("peer + \(entry.nickname) (\(senderPeer.id.prefix(8)))")
            WKInterfaceDevice.current().play(.directionUp)
        } else if nicknameChanged {
            log("peer ~ \(entry.nickname) (\(senderPeer.id.prefix(8)))")
        }

        let now = Date()
        let lastResponse = lastAnnounceBackAt[senderPeer.id] ?? .distantPast
        let responseDue = now.timeIntervalSince(lastResponse)
            >= Self.directAnnounceResponseInterval
        if directAssociationChanged
            || ((isNew || nicknameChanged || isDirectAnnounce) && responseDue) {
            lastAnnounceBackAt[senderPeer.id] = now
            sendAnnounceToAllLinks()
        }
        if isDirectAnnounce {
            requestPublicSyncIfNeeded(on: linkUUID)
        }
        initiateNoiseHandshake(with: senderPeer)
    }

    private func handlePublicMessage(_ packet: BitchatPacket, from senderPeer: PeerID) {
        guard packet.recipientID == nil || packet.recipientID == WatchPacketFactory.broadcastRecipient,
              let knownPeer = peer(senderPeer),
              WatchPacketFactory.verify(packet, signingPublicKey: knownPeer.signingPublicKey),
              packet.payload.count <= Self.maxPublicContentBytes,
              let content = String(data: packet.payload, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let messageID = WatchPacketFactory.stableMessageID(
            senderIDHex: senderPeer.id,
            timestampMs: packet.timestamp,
            content: content
        )
        gossipStore.record(packet)
        guard seenMessageIDs.insert(messageID).inserted else { return }
        messages.append(WatchChatMessage(
            id: messageID,
            sender: knownPeer.nickname,
            senderPeerID: senderPeer,
            content: content,
            timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
            isSelf: false,
            isPrivate: false,
            conversationPeerID: nil,
            status: "",
            media: nil
        ))
        trimTimelineIfNeeded()
        if WatchNotifications.shouldScheduleAlert(
            isAppInteractive: isAppInteractive,
            isConversationActive: isPublicConversationActive
        ) {
            WatchNotifications.notifyPublicMessage(
                messageID: messageID,
                sender: knownPeer.nickname,
                preview: content
            ) { [weak self] error in
                self?.recordNotificationResult(error, messageID: messageID)
            }
        } else {
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func handlePublicVoiceFrame(
        _ packet: BitchatPacket,
        from senderPeer: PeerID
    ) {
        guard packet.recipientID == nil
                || packet.recipientID == WatchPacketFactory.broadcastRecipient,
              let knownPeer = peer(senderPeer),
              packet.payload.count <= TransportConfig.pttMaxBurstContentBytes,
              WatchPacketFactory.verify(
                packet,
                signingPublicKey: knownPeer.signingPublicKey
              ) else { return }
        let timestamp = Date(
            timeIntervalSince1970: Double(packet.timestamp) / 1_000
        )
        guard abs(timestamp.timeIntervalSinceNow)
                <= TransportConfig.pttPublicFrameMaxAgeSeconds else { return }
        liveVoiceCoordinator.handle(
            packet.payload,
            from: senderPeer,
            scope: .publicMesh,
            nickname: knownPeer.nickname,
            timestamp: timestamp
        )
    }

    private func handleLeave(_ packet: BitchatPacket, from senderPeer: PeerID) {
        guard let knownPeer = peer(senderPeer),
              WatchPacketFactory.verify(packet, signingPublicKey: knownPeer.signingPublicKey) else {
            return
        }
        peers.removeAll { $0.peerID == senderPeer }
        noise.clear(senderPeer)
        peerSecurity.clear(senderPeer)
        pendingAnnouncements.removeValue(forKey: senderPeer)
        pendingPrivateMediaPayloads.removeValue(forKey: senderPeer)
        deferredEncryptedPackets.removeValue(forKey: senderPeer)
        log("peer - \(knownPeer.nickname) (\(senderPeer.id.prefix(8)))")
    }

    private func handleFileTransfer(_ packet: BitchatPacket, from senderPeer: PeerID) {
        let directedToUs = packet.recipientID == identity.peerIDData
        guard packet.recipientID == nil
                || packet.recipientID == WatchPacketFactory.broadcastRecipient
                || directedToUs else {
            log("file reject: recipient mismatch")
            return
        }
        guard let knownPeer = peer(senderPeer) else {
            log("file reject: unknown sender \(senderPeer.id.prefix(8))")
            return
        }
        guard WatchPacketFactory.verify(packet, signingPublicKey: knownPeer.signingPublicKey) else {
            log("file reject: bad signature from \(senderPeer.id.prefix(8))")
            return
        }
        // Directed legacy private transfers are point-to-point, not gossip.
        if !directedToUs { gossipStore.record(packet) }
        handleFilePayload(
            packet.payload,
            from: senderPeer,
            timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
            isPrivate: directedToUs,
            usesDurableReceipts: false
        )
    }

    private func handleFilePayload(
        _ payload: Data,
        from peerID: PeerID,
        timestamp: Date,
        isPrivate: Bool,
        usesDurableReceipts: Bool = true
    ) {
        guard let packet = WatchFilePacket.decode(payload) else {
            log("file reject: malformed payload (\(payload.count)B)")
            return
        }
        let wireName = ((packet.fileName ?? "file") as NSString).lastPathComponent
        let stableMessageID = isPrivate && usesDurableReceipts
            ? PrivateMediaReceiptPolicy.stableMessageID(
                peerCapabilities: peer(peerID)?.capabilities ?? [],
                senderPeerID: peerID,
                recipientPeerID: identity.peerID,
                fileName: wireName
            )
            : nil
        let messageID = stableMessageID ?? (
            "media-" + WatchPacketFactory.stableMessageID(
                senderIDHex: peerID.id,
                timestampMs: Self.timestampMilliseconds(from: timestamp),
                content: wireName
            )
        )
        if let stableMessageID {
            switch privateMediaReceipts.state(for: stableMessageID) {
            case .accepted(let storedURL):
                seenMessageIDs.insert(stableMessageID)
                restoreAcceptedPrivateMediaIfNeeded(
                    messageID: stableMessageID,
                    storedURL: storedURL,
                    fallbackMimeType: packet.mimeType,
                    from: peerID,
                    timestamp: timestamp
                )
                acknowledgeDurablePrivateMediaReplay(
                    messageID: stableMessageID,
                    from: peerID
                )
                log("file replay acknowledged \(stableMessageID.prefix(12))…")
                return
            case .tombstoned:
                sendReceipt(type: .delivered, messageID: stableMessageID, to: peerID)
                log("file replay tombstoned \(stableMessageID.prefix(12))…")
                return
            case .unavailable:
                log("file receipt ledger unavailable \(stableMessageID.prefix(12))…")
                return
            case .absent:
                break
            }
        } else {
            // Legacy/public IDs have no durable receiver decision. Keep their
            // process/archive deduplication behavior without promising retries.
            guard !seenMessageIDs.contains(messageID) else { return }
        }
        guard let attachment = WatchMediaStore.save(packet) else {
            log("file reject: validation or save failed (\(packet.content.count)B)")
            return
        }
        if let stableMessageID,
           !privateMediaReceipts.commitAccepted(
               messageID: stableMessageID,
               storedURL: attachment.url
           ) {
            WatchMediaStore.remove(attachment)
            log("file reject: durable receipt commit failed")
            return
        }
        log("file ✓ \(attachment.byteCount)B " + (isPrivate ? "private" : "public"))
        let nickname = peer(peerID)?.nickname ?? String(peerID.id.prefix(8))
        seenMessageIDs.insert(messageID)
        if attachment.kind == .audio,
           liveVoiceCoordinator.absorbFinalizedVoiceNote(
            attachment: attachment,
            wireFileName: wireName,
            messageID: messageID,
            from: peerID,
            nickname: nickname,
            timestamp: timestamp,
            isPrivate: isPrivate
           ) {
            log("PTT finalized note adopted")
            return
        }
        let message = WatchChatMessage(
            id: messageID,
            sender: nickname,
            senderPeerID: peerID,
            content: attachment.fileName,
            timestamp: timestamp,
            isSelf: false,
            isPrivate: isPrivate,
            conversationPeerID: isPrivate ? peerID : nil,
            status: "",
            media: attachment,
            supportsReceipts: !isPrivate || stableMessageID != nil
        )
        if isPrivate {
            appendPrivateMessage(message, peerID: peerID)
            didReceiveDirectMessage(
                id: messageID,
                from: peerID,
                sender: nickname,
                preview: attachment.kind == .audio ? "Voice message" : attachment.fileName,
                sendsReceipts: stableMessageID != nil
            )
        } else {
            messages.append(message)
            trimTimelineIfNeeded()
            if WatchNotifications.shouldScheduleAlert(
                isAppInteractive: isAppInteractive,
                isConversationActive: isPublicConversationActive
            ) {
                let preview = attachment.kind == .audio
                    ? "Voice message"
                    : attachment.fileName
                WatchNotifications.notifyPublicMessage(
                    messageID: messageID,
                    sender: nickname,
                    preview: preview
                ) { [weak self] error in
                    self?.recordNotificationResult(error, messageID: messageID)
                }
            } else {
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    private func handleFragment(_ packet: BitchatPacket, from senderPeer: PeerID, linkUUID: UUID) {
        guard let header = WatchFragmentHeader(packet: packet) else {
            log("fragment reject: malformed header (\(packet.payload.count)B)")
            return
        }
        gossipStore.record(packet)
        let fragmentID = String(format: "%016llx", header.id)
        let assembled: Data
        switch fragmentAssembler.append(header) {
        case let .stored(received, total, started):
            if started {
                log(
                    "fragment start \(fragmentID) type=0x"
                        + String(header.originalType, radix: 16)
                        + " total=\(total)"
                )
            } else if received == total - 1 {
                log("fragment waiting \(fragmentID) \(received)/\(total)")
            }
            scheduleFragmentRecoveryCheck()
            return
        case let .complete(data):
            assembled = data
            log("fragment ✓ \(fragmentID) \(header.total)/\(header.total) \(data.count)B")
        case let .rejected(reason):
            log("fragment reject \(fragmentID): \(reason)")
            return
        }
        guard var inner = BitchatPacket.from(assembled) else {
            log("fragment reject \(fragmentID): inner packet decode failed")
            return
        }
        guard inner.type == header.originalType,
              isForLocalDelivery(inner) else {
            log("fragment reject \(fragmentID): inner metadata mismatch")
            return
        }
        let innerSender = PeerID(hexData: inner.senderID)
        guard innerSender == senderPeer else {
            log("fragment reject \(fragmentID): sender mismatch")
            return
        }
        if let reason = admissionFailure(for: inner, from: innerSender) {
            log("fragment reject \(fragmentID): \(reason)")
            return
        }
        inner.ttl = 0
        process(inner, from: innerSender, linkUUID: linkUUID)
        if !isAppInForeground { enforceBackgroundConnectionBudget() }
    }

    private func scheduleFragmentRecoveryCheck() {
        guard fragmentRecoveryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fragmentRecoveryWorkItem = nil
            self.requestStalledFragments()
            if self.fragmentAssembler.hasActiveAssemblies {
                self.scheduleFragmentRecoveryCheck()
            }
        }
        fragmentRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func requestStalledFragments() {
        // Same budget rule as gossip sync: resync requests invite bursts,
        // so fragment recovery waits for granted foreground runtime.
        guard isAppInForeground else { return }
        let ids = fragmentAssembler.stalledBroadcastFragmentIDs(
            stalledAfter: 5,
            retryAfter: 10,
            limit: 60
        )
        guard !ids.isEmpty,
              let payload = WatchRequestSyncPacket.fragmentRecoveryPayload(fragmentIDs: ids),
              let packet = WatchPacketFactory.requestSyncPacket(
                identity: identity,
                payload: payload
              ) else {
            return
        }
        let sent = broadcast(packet)
        log("fragment resync \(ids.count) stream(s) → \(sent) link(s)")
    }

    // MARK: - Message state

    private func conversationSnapshot() -> WatchConversationSnapshot {
        WatchConversationSnapshot(
            messages: messages,
            privateMessages: privateMessages,
            unreadDms: unreadDms
        )
    }

    private func scheduleConversationPersistence() {
        guard !isRestoringConversation, !WatchDemoMode.isEnabled else { return }
        conversationPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.conversationPersistenceWorkItem = nil
            self.enforceMediaRetention()
            self.conversationStore.save(self.conversationSnapshot())
            self.pruneUnreferencedMedia()
        }
        conversationPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.35,
            execute: workItem
        )
    }

    private func flushConversationPersistence() {
        guard !isRestoringConversation, !WatchDemoMode.isEnabled else { return }
        conversationPersistenceWorkItem?.cancel()
        conversationPersistenceWorkItem = nil
        enforceMediaRetention()
        conversationStore.flush(conversationSnapshot())
        pruneUnreferencedMedia()
    }

    private func enforceMediaRetention() {
        let publicCandidates = messages.compactMap { message in
            message.media.map {
                WatchMediaStore.RetentionCandidate(
                    url: $0.url,
                    byteCount: $0.byteCount,
                    timestamp: message.timestamp
                )
            }
        }
        let privateCandidates = privateMessages.values.joined().compactMap { message in
            message.media.map {
                WatchMediaStore.RetentionCandidate(
                    url: $0.url,
                    byteCount: $0.byteCount,
                    timestamp: message.timestamp
                )
            }
        }
        let victims = WatchMediaStore.retentionVictimURLs(
            from: publicCandidates + privateCandidates
        )
        guard !victims.isEmpty else { return }
        let victimPaths = Set(victims.map { $0.standardizedFileURL.path })

        var updatedPublic = messages
        var changedPublic = false
        for index in updatedPublic.indices {
            guard let attachment = updatedPublic[index].media,
                  victimPaths.contains(attachment.url.standardizedFileURL.path) else {
                continue
            }
            WatchMediaStore.remove(attachment)
            updatedPublic[index].media = nil
            changedPublic = true
        }
        if changedPublic { messages = updatedPublic }

        var updatedPrivate = privateMessages
        var changedPrivate = false
        for peerIDString in Array(updatedPrivate.keys) {
            guard var thread = updatedPrivate[peerIDString] else { continue }
            let peerID = PeerID(str: peerIDString)
            var changedThread = false
            for index in thread.indices {
                guard let attachment = thread[index].media,
                      victimPaths.contains(attachment.url.standardizedFileURL.path) else {
                    continue
                }
                if !thread[index].isSelf,
                   PrivateMediaMessageIdentity.isStableID(thread[index].id) {
                    // Commit the deletion decision before unlinking so a
                    // sender retry cannot recreate intentionally expired media.
                    guard privateMediaReceipts.recordDeleted(
                        messageID: thread[index].id
                    ) else { continue }
                } else {
                    WatchMediaStore.remove(attachment)
                }
                if thread[index].isSelf {
                    let messageID = thread[index].id
                    cancelPrivateMediaRetry(messageID)
                    pendingPrivateMediaPayloads[peerID]?.removeAll {
                        $0.messageID == messageID
                    }
                    if thread[index].status != "delivered"
                        && thread[index].status != "read" {
                        thread[index].status = "failed"
                    }
                }
                thread[index].media = nil
                changedThread = true
            }
            if changedThread {
                updatedPrivate[peerIDString] = thread
                changedPrivate = true
            }
        }
        if changedPrivate { privateMessages = updatedPrivate }
    }

    private func pruneUnreferencedMedia() {
        let publicURLs = messages.compactMap { $0.media?.url }
        let privateURLs = privateMessages.values
            .joined()
            .compactMap { $0.media?.url }
        _ = WatchMediaStore.prune(
            protectedURLs: Set(publicURLs + privateURLs)
        )
    }

    private func appendPrivateMessage(_ message: WatchChatMessage, peerID: PeerID) {
        var thread = privateMessages[peerID.id] ?? []
        guard !thread.contains(where: { $0.id == message.id }) else { return }
        thread.append(message)
        thread.sort { $0.timestamp < $1.timestamp }
        if thread.count > Self.maxDirectMessagesPerPeer {
            thread.removeFirst(thread.count - Self.maxDirectMessagesPerPeer)
        }
        privateMessages[peerID.id] = thread
    }

    private func upsertPrivateMessage(_ message: WatchChatMessage, peerID: PeerID) {
        var thread = privateMessages[peerID.id] ?? []
        if let index = thread.firstIndex(where: { $0.id == message.id }) {
            thread[index] = message
        } else {
            thread.append(message)
        }
        thread.sort { $0.timestamp < $1.timestamp }
        if thread.count > Self.maxDirectMessagesPerPeer {
            thread.removeFirst(thread.count - Self.maxDirectMessagesPerPeer)
        }
        privateMessages[peerID.id] = thread
    }

    @discardableResult
    private func removePrivateMessage(_ messageID: String, peerID: PeerID) -> Bool {
        guard var thread = privateMessages[peerID.id],
              let index = thread.firstIndex(where: { $0.id == messageID }) else {
            return false
        }
        thread.remove(at: index)
        privateMessages[peerID.id] = thread
        return true
    }

    private func upsertPublicMessage(_ message: WatchChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort { $0.timestamp < $1.timestamp }
        trimTimelineIfNeeded()
    }

    private func removePublicMessage(_ messageID: String) {
        messages.removeAll { $0.id == messageID }
    }

    private func didReceiveDirectMessage(
        id: String,
        from peerID: PeerID,
        sender: String,
        preview: String,
        sendsReceipts: Bool = true
    ) {
        if sendsReceipts {
            sendReceipt(type: .delivered, messageID: id, to: peerID)
        }
        let shouldScheduleAlert = WatchNotifications.shouldScheduleAlert(
            isAppInteractive: isAppInteractive,
            isConversationActive: activeDMPeer == peerID
        )
        if !shouldScheduleAlert {
            if sendsReceipts {
                sendReadReceiptIfNeeded(messageID: id, to: peerID)
            }
        } else {
            unreadDms[peerID.id, default: 0] += 1
            sortPeers()
            WatchNotifications.notifyDirectMessage(
                messageID: id,
                peerID: peerID.id,
                sender: sender,
                preview: preview
            ) { [weak self] error in
                self?.recordNotificationResult(error, messageID: id)
            }
        }
        if !shouldScheduleAlert {
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func recordNotificationResult(_ error: Error?, messageID: String) {
        // The Bluetooth callback which woke us is not necessarily the message:
        // announces and fragments use the same characteristic. Release the
        // scarce watchOS background task only after UNUserNotificationCenter has
        // accepted (or rejected) the completely assembled, user-visible message.
        pendingTimelyAlertSignalIDs.removeAll()
        bluetoothAlertGate.signal()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let error {
                self.backgroundAlertState = "notification error"
                self.log(
                    "notification failed \(messageID.prefix(12)): "
                        + error.localizedDescription
                )
            } else {
                self.backgroundAlertState = "notified"
                self.log("notification scheduled \(messageID.prefix(12))")
            }
        }
    }

    private func sendReadReceiptIfNeeded(messageID: String, to peerID: PeerID) {
        let receiptID = "\(peerID.id):\(messageID)"
        guard sentReadReceiptIDs.insert(receiptID).inserted else { return }
        sendReceipt(type: .readReceipt, messageID: messageID, to: peerID)
    }

    private func acknowledgeDurablePrivateMediaReplay(
        messageID: String,
        from peerID: PeerID
    ) {
        sendReceipt(type: .delivered, messageID: messageID, to: peerID)
        if isAppInteractive, activeDMPeer == peerID {
            sentReadReceiptIDs.insert("\(peerID.id):\(messageID)")
            sendReceipt(type: .readReceipt, messageID: messageID, to: peerID)
        }
    }

    private func restoreAcceptedPrivateMediaIfNeeded(
        messageID: String,
        storedURL: URL,
        fallbackMimeType: String?,
        from peerID: PeerID,
        timestamp: Date
    ) {
        guard privateMessages[peerID.id]?.contains(where: {
            $0.id == messageID
        }) != true else {
            return
        }
        let attachment = WatchMediaStore.attachment(
            forStoredURL: storedURL,
            fallbackMimeType: fallbackMimeType
        )
        let nickname = peer(peerID)?.nickname ?? String(peerID.id.prefix(8))
        appendPrivateMessage(
            WatchChatMessage(
                id: messageID,
                sender: nickname,
                senderPeerID: peerID,
                content: attachment.fileName,
                timestamp: timestamp,
                isSelf: false,
                isPrivate: true,
                conversationPeerID: peerID,
                status: "",
                media: attachment,
                supportsReceipts: true
            ),
            peerID: peerID
        )
        didReceiveDirectMessage(
            id: messageID,
            from: peerID,
            sender: nickname,
            preview: attachment.kind == .audio
                ? "Voice message"
                : attachment.fileName,
            sendsReceipts: false
        )
    }

    private func migratePrivateMediaReceiptsFromConversation() {
        for message in privateMessages.values.joined() {
            guard !message.isSelf,
                  PrivateMediaMessageIdentity.isStableID(message.id),
                  let attachment = message.media else {
                continue
            }
            _ = privateMediaReceipts.commitAccepted(
                messageID: message.id,
                storedURL: attachment.url
            )
        }
    }

    private func updatePublicStatus(_ id: String, status: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = status
    }

    private func updatePrivateStatus(_ id: String, peerID: PeerID, status: String) {
        guard var thread = privateMessages[peerID.id],
              let index = thread.firstIndex(where: { $0.id == id }) else { return }
        guard thread[index].updateDeliveryStatus(status) else { return }
        privateMessages[peerID.id] = thread
    }

    private func trimTimelineIfNeeded() {
        if messages.count > Self.maxTimelineMessages {
            messages.removeFirst(messages.count - Self.maxTimelineMessages)
        }
    }

    private static func truncateToByteLimit(_ string: String, _ limit: Int) -> String {
        let data = Data(string.utf8)
        guard data.count > limit else { return string }
        return String(data: data.prefix(limit), encoding: .utf8)
            ?? String(string.prefix(limit / 4))
    }

    private static func timestampMilliseconds(from date: Date) -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value)
    }

    // MARK: - Routing, fragmentation, housekeeping

    private func isForLocalDelivery(_ packet: BitchatPacket) -> Bool {
        guard let recipient = packet.recipientID else { return true }
        return recipient == WatchPacketFactory.broadcastRecipient
            || recipient == identity.peerIDData
    }

    private func relayIfNeeded(_ packet: BitchatPacket, arrivedFrom linkUUID: UUID) {
        guard packet.type != MessageType.requestSync.rawValue else { return }
        guard packet.ttl > 1 else { return }
        if let recipient = packet.recipientID, recipient == identity.peerIDData {
            return
        }
        let targets = writableCharacteristics.keys.filter { $0 != linkUUID }
        guard !targets.isEmpty else { return }
        var relayed = packet
        relayed.ttl -= 1
        let priority: WritePriority = switch MessageType(rawValue: packet.type) {
        case .fragment, .fileTransfer: .normal
        default: .realtime
        }
        let sent = transmit(relayed, to: targets, priority: priority)
        if sent > 0 {
            log("relay 0x\(String(packet.type, radix: 16)) ttl \(packet.ttl)→\(relayed.ttl)")
        }
    }

    @discardableResult
    private func broadcast(
        _ packet: BitchatPacket,
        priority: WritePriority = .normal
    ) -> Int {
        transmit(
            packet,
            to: Array(writableCharacteristics.keys),
            priority: priority
        )
    }

    @discardableResult
    private func transmit(
        _ packet: BitchatPacket,
        to targets: [UUID],
        priority: WritePriority = .normal
    ) -> Int {
        let type = MessageType(rawValue: packet.type)
        let padsPayload = type == .noiseEncrypted || type == .noiseHandshake
        guard !targets.isEmpty,
              let fullData = packet.toBinaryData(padding: padsPayload) else { return 0 }
        let available = targets.compactMap { uuid -> (id: UUID, limit: Int)? in
            guard let peripheral = peripherals[uuid], peripheral.state == .connected,
                  writableCharacteristics[uuid] != nil else { return nil }
            return (uuid, peripheral.maximumWriteValueLength(for: .withoutResponse))
        }
        guard let minimumMTU = available.map(\.limit).min() else { return 0 }
        let eligibleTargets = available.map(\.id)

        if fullData.count <= minimumMTU {
            markSeen(fullData)
            return eligibleTargets.reduce(0) { count, uuid in
                count + (write(fullData, to: uuid, priority: priority) ? 1 : 0)
            }
        }

        let fragmentID = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let fragmentVersion: UInt8 = packet.route?.isEmpty == false ? 2 : 1
        let template = makeFragmentPacket(
            original: packet,
            fragmentID: fragmentID,
            index: 0,
            total: 1,
            chunk: Data(),
            version: fragmentVersion
        )
        guard let templateData = template.toBinaryData(padding: false) else { return 0 }
        let compressionLengthReserve = fragmentVersion == 2 ? 4 : 2
        let chunkSize = minimumMTU - templateData.count - compressionLengthReserve
        guard chunkSize > 0 else {
            log("fragment envelope exceeds MTU \(minimumMTU)")
            return 0
        }
        let fragmentCeiling: Int = {
            guard packet.type == MessageType.noiseEncrypted.rawValue,
                  let recipient = PeerID(hexData: packet.recipientID),
                  case let .encrypted(_, _, supportsExtended) =
                    peerSecurity.sendPolicy(
                        peerID: recipient,
                        authenticatedSession: noise.authenticatedSession(for: recipient)
                    ), supportsExtended else {
                return Self.maxCrossPlatformFragments
            }
            return Self.maxExtendedFragments
        }()
        guard let fragmentCount = FragmentationLimits.requiredFragmentCount(
            byteCount: fullData.count,
            chunkSize: chunkSize
        ), fragmentCount <= fragmentCeiling else {
            log(
                "fragment plan exceeds negotiated ceiling "
                    + "\(fragmentCeiling)"
            )
            return 0
        }
        let chunks = stride(from: 0, to: fullData.count, by: chunkSize).map {
            Data(fullData[$0..<min($0 + chunkSize, fullData.count)])
        }
        guard chunks.count == fragmentCount else { return 0 }
        let fragmentSpacing =
            packet.recipientID == nil
                || packet.recipientID == WatchPacketFactory.broadcastRecipient
            ? Self.publicFragmentSpacing
            : Self.directedFragmentSpacing
        let fragmentPackets = chunks.enumerated().map { index, chunk in
            makeFragmentPacket(
                original: packet,
                fragmentID: fragmentID,
                index: index,
                total: chunks.count,
                chunk: chunk,
                version: fragmentVersion
            )
        }
        fragmentPackets.forEach(gossipStore.record)
        let frames = fragmentPackets.compactMap {
            $0.toBinaryData(padding: false)
        }
        guard frames.count == chunks.count,
              frames.allSatisfy({ $0.count <= minimumMTU }) else {
            log("fragment sizing failed for MTU \(minimumMTU)")
            return 0
        }
        sendFragmentFrames(
            frames,
            index: 0,
            targets: eligibleTargets,
            spacing: fragmentSpacing,
            priority: priority
        )
        log("fragment tx \(fullData.count)B as \(chunks.count) × \(chunkSize)B")
        return eligibleTargets.count
    }

    private func makeFragmentPacket(
        original packet: BitchatPacket,
        fragmentID: Data,
        index: Int,
        total: Int,
        chunk: Data,
        version: UInt8
    ) -> BitchatPacket {
        var payload = fragmentID
        var bigIndex = UInt16(index).bigEndian
        var bigTotal = UInt16(total).bigEndian
        withUnsafeBytes(of: &bigIndex) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigTotal) { payload.append(contentsOf: $0) }
        payload.append(packet.type)
        payload.append(chunk)
        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: payload,
            signature: nil,
            ttl: packet.ttl,
            version: version,
            route: packet.route,
            isRSR: packet.isRSR
        )
    }

    private func sendFragmentFrames(
        _ frames: [Data],
        index: Int,
        targets: [UUID],
        spacing: TimeInterval,
        priority: WritePriority
    ) {
        guard running, frames.indices.contains(index) else { return }
        let frame = frames[index]
        markSeen(frame)
        for target in targets {
            _ = write(frame, to: target, priority: priority)
        }
        let next = index + 1
        guard frames.indices.contains(next) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + spacing) { [weak self] in
            self?.sendFragmentFrames(
                frames,
                index: next,
                targets: targets,
                spacing: spacing,
                priority: priority
            )
        }
    }

    private func markSeen(_ data: Data) {
        seenPacketHashes[Self.packetDigest(data)] = Date()
    }

    private static func packetDigest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func touch(_ peerID: PeerID) {
        let now = Date()
        if let index = peers.firstIndex(where: { $0.peerID == peerID }) {
            peers[index].lastSeen = now
            return
        }
        // A freshly verified message is presence evidence in its own right.
        // Restore the cached identity into the active People list so the watch
        // does not show "0" while displaying that peer's current message.
        guard var remembered = knownPeerStore.peer(peerID) else { return }
        remembered.lastSeen = now
        evictOldestPeerIfNeeded()
        peers.append(remembered)
        knownPeerStore.remember(remembered)
        sortPeers()
    }

    private func evictOldestPeerIfNeeded() {
        guard peers.count >= Self.maxPeerCount,
              let oldest = peers.min(by: { $0.lastSeen < $1.lastSeen })?.peerID else { return }
        peers.removeAll { $0.peerID == oldest }
        noise.clear(oldest)
        peerSecurity.clear(oldest)
        pendingAnnouncements.removeValue(forKey: oldest)
        deferredEncryptedPackets.removeValue(forKey: oldest)
        pendingNoisePayloads.removeValue(forKey: oldest)
        pendingPrivateMediaPayloads.removeValue(forKey: oldest)
        lastHandshakeAttemptAt.removeValue(forKey: oldest.id)
        lastAnnounceBackAt.removeValue(forKey: oldest.id)
    }

    private func sortPeers() {
        peers.sort {
            let leftUnread = unreadDms[$0.peerID.id, default: 0] > 0
            let rightUnread = unreadDms[$1.peerID.id, default: 0] > 0
            if leftUnread != rightUnread { return leftUnread }
            return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
        }
    }

    private func housekeepingIfNeeded() {
        guard Date().timeIntervalSince(lastHousekeeping) > 30 else { return }
        lastHousekeeping = Date()
        fragmentAssembler.expire()
        let packetCutoff = Date().addingTimeInterval(-600)
        seenPacketHashes = seenPacketHashes.filter { $0.value > packetCutoff }
        if seenMessageIDs.count > 1_000 {
            seenMessageIDs = Set(seenMessageIDs.suffix(750))
        }
        if sentReadReceiptIDs.count > 1_000 {
            sentReadReceiptIDs = Set(sentReadReceiptIDs.suffix(750))
        }
        guard WatchMeshRuntimePolicy.shouldExpirePeerPresence(
            isAppInForeground: isAppInForeground
        ) else { return }
        let peerCutoff = Date().addingTimeInterval(
            -WatchMeshRuntimePolicy.peerPresenceTimeout
        )
        let expired = peers.filter { $0.lastSeen < peerCutoff }.map(\.peerID)
        peers.removeAll { $0.lastSeen < peerCutoff }
        for peerID in expired {
            // Presence and authentication have different lifetimes on
            // watchOS. Alert-only background links suppress announcements, so
            // a stale People entry must not destroy a valid Noise session or
            // pending delivery state. Explicit LEAVE, link/auth failures and
            // process teardown remain the retirement paths.
            pendingAnnouncements.removeValue(forKey: peerID)
            lastAnnounceBackAt.removeValue(forKey: peerID.id)
        }
    }

    @discardableResult
    private func write(
        _ data: Data,
        to uuid: UUID,
        priority: WritePriority
    ) -> Bool {
        guard let peripheral = peripherals[uuid], peripheral.state == .connected,
              let characteristic = writableCharacteristics[uuid] else { return false }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= maximum else {
            log("write: \(data.count)B exceeds MTU \(maximum)")
            return false
        }

        if pendingWrites[uuid] == nil, peripheral.canSendWriteWithoutResponse {
            writeImmediately(data, to: peripheral, characteristic: characteristic)
            return true
        }

        var queue = pendingWrites.removeValue(forKey: uuid) ?? PendingWriteQueue()
        guard queue.enqueue(
            data,
            priority: priority,
            maximumBytes: Self.maximumQueuedWriteBytes
        ) else {
            pendingWrites[uuid] = queue
            log("write queue full for \(uuid.uuidString.prefix(8))")
            return false
        }
        pendingWrites[uuid] = queue
        drainPendingWrites(for: peripheral)
        return true
    }

    private func drainPendingWrites(for peripheral: CBPeripheral) {
        let uuid = peripheral.identifier
        guard peripheral.state == .connected,
              let characteristic = writableCharacteristics[uuid],
              var queue = pendingWrites.removeValue(forKey: uuid) else { return }

        while peripheral.canSendWriteWithoutResponse,
              let data = queue.dequeue() {
            writeImmediately(data, to: peripheral, characteristic: characteristic)
        }
        if !queue.isEmpty {
            pendingWrites[uuid] = queue
        }
    }

    private func writeImmediately(
        _ data: Data,
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        txBytes += data.count
    }

    // MARK: - Logging

    private func openLogFile() {
        guard let url = Self.logFileURL() else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        logFileHandle = try? FileHandle(forWritingTo: url)
        guard let logFileHandle else { return }
        let fileSize = (try? logFileHandle.seekToEnd()) ?? 0
        if fileSize > Self.maximumLogFileBytes {
            try? logFileHandle.truncate(atOffset: 0)
            try? logFileHandle.seek(toOffset: 0)
            logFileBytes = 0
        } else {
            logFileBytes = fileSize
        }
    }

    static func logFileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(logFileName)
    }

    private func log(_ message: String) {
        let line = "\(Self.timeStamp()) \(message)"
        logger.log("\(message, privacy: .public)")
        if logFileHandle == nil { openLogFile() }
        if let data = (line + "\n").data(using: .utf8),
           let logFileHandle {
            do {
                let incomingBytes = UInt64(data.count)
                if incomingBytes > Self.maximumLogFileBytes {
                    return
                }
                if logFileBytes > Self.maximumLogFileBytes - incomingBytes {
                    try logFileHandle.truncate(atOffset: 0)
                    try logFileHandle.seek(toOffset: 0)
                    logFileBytes = 0
                }
                try logFileHandle.write(contentsOf: data)
                logFileBytes += incomingBytes
            } catch {
                try? logFileHandle.close()
                self.logFileHandle = nil
                logFileBytes = 0
            }
        }
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 250 {
                self.logLines.removeFirst(self.logLines.count - 250)
            }
        }
    }

    private static func timeStamp() -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return String(
            format: "%02d:%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}

// MARK: - Live voice integration

extension WatchBLEController: WatchLiveVoiceCoordinatorDelegate {
    func liveVoiceShouldAutoplay(
        from peerID: PeerID,
        scope: WatchVoiceBurstScope
    ) -> Bool {
        guard isAppInteractive else { return false }
        switch scope {
        case .directMessage:
            return activeDMPeer == peerID
        case .publicMesh:
            return isPublicConversationActive
        }
    }

    func liveVoiceUpsert(_ message: WatchChatMessage, peerID: PeerID?) {
        if let peerID {
            upsertPrivateMessage(message, peerID: peerID)
        } else {
            upsertPublicMessage(message)
        }
    }

    func liveVoiceRemove(messageID: String, peerID: PeerID?) {
        if let peerID {
            let removed = removePrivateMessage(messageID, peerID: peerID)
            if removed, (!isAppInteractive || activeDMPeer != peerID),
               let unread = unreadDms[peerID.id], unread > 0 {
                if unread == 1 {
                    unreadDms.removeValue(forKey: peerID.id)
                } else {
                    unreadDms[peerID.id] = unread - 1
                }
            }
        } else {
            removePublicMessage(messageID)
        }
    }

    func liveVoiceDidStartDirectMessage(
        id: String,
        from peerID: PeerID,
        sender: String
    ) {
        didReceiveDirectMessage(
            id: id,
            from: peerID,
            sender: sender,
            preview: "Live voice message"
        )
    }

    func liveVoiceDidAdoptFinalizedDirectMessage(
        oldMessageID: String,
        message: WatchChatMessage,
        from peerID: PeerID
    ) {
        let oldReceiptID = "\(peerID.id):\(oldMessageID)"
        let shouldSendRead = (isAppInteractive && activeDMPeer == peerID)
            || sentReadReceiptIDs.contains(oldReceiptID)

        // Insert first so replacing the only message never transiently drops
        // the conversation, then remove the receiver-local live ID.
        upsertPrivateMessage(message, peerID: peerID)
        if message.id != oldMessageID {
            _ = removePrivateMessage(oldMessageID, peerID: peerID)
        }
        sendReceipt(type: .delivered, messageID: message.id, to: peerID)
        if shouldSendRead {
            sendReadReceiptIfNeeded(messageID: message.id, to: peerID)
        }
    }

    func liveVoiceSetPublicTalker(_ nickname: String?) {
        activePublicVoiceTalker = nickname
    }

    func liveVoiceLog(_ message: String) {
        log(message)
    }
}

// MARK: - Core Bluetooth

extension WatchBLEController: CBCentralManagerDelegate {
    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard central === centralManager else { return }
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral] else {
            return
        }
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheralLastDiscoveredAt[peripheral.identifier] = Date()
            peripheral.delegate = self
            if peripheral.state == .connecting {
                connectionRequestedAt[peripheral.identifier] = Date()
                markConnectionPhase(.connecting, for: peripheral.identifier)
            } else if peripheral.state == .connected {
                connectedAt[peripheral.identifier] = Date()
            }
        }
        lastBluetoothProgressAt = Date()
        log("restored \(restored.count) Bluetooth link(s)")
        resumeKnownPeripherals()
        enforceBackgroundConnectionBudget()
        reconcileDiscoveryState()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === centralManager else { return }
        switch central.state {
        case .poweredOn: centralState = "poweredOn"
        case .poweredOff: centralState = "poweredOff"
        case .unauthorized: centralState = "unauthorized"
        case .unsupported: centralState = "unsupported"
        case .resetting: centralState = "resetting"
        case .unknown: centralState = "unknown"
        @unknown default: centralState = "unknown"
        }
        log("central state: \(centralState)")
        guard running, central.state == .poweredOn else {
            if central.state == .poweredOff || central.state == .resetting {
                connectionRequestedAt.removeAll()
                connectionPhases.removeAll()
                discoveryCandidates.removeAll()
                writableCharacteristics.removeAll()
                alertCharacteristics.removeAll()
                announcedReadyLinks.removeAll()
                directPeerByLink.removeAll()
                pendingWrites.removeAll()
                for workItem in meshNotificationTimeoutWorkItems.values {
                    workItem.cancel()
                }
                meshNotificationTimeoutWorkItems.removeAll()
                meshNotificationRequests.removeAll()
                meshNotificationFailureCounts.removeAll()
                connectedAt.removeAll()
                refreshConnectionDiagnostics()
            }
            refreshAnnounceHeartbeat()
            return
        }
        lastBluetoothProgressAt = Date()
        adoptSystemConnectedPeripherals()
        resumeKnownPeripherals()
        enforceBackgroundConnectionBudget()
        reconcileDiscoveryState()
    }

    private var pendingConnectionIDs: Set<UUID> {
        var result = Set(connectionRequestedAt.keys)
        for peripheral in peripherals.values {
            if peripheral.state == .connecting {
                result.insert(peripheral.identifier)
            }
        }
        return result
    }

    private var physicalConnectionIDs: Set<UUID> {
        Set(peripherals.values.compactMap {
            $0.state == .connected ? $0.identifier : nil
        })
    }

    private var shouldKeepDiscoveryArmed: Bool {
        WatchMeshRuntimePolicy.shouldRunDiscovery(
            isAppInForeground: isAppInForeground,
            physicalLinks: physicalConnectionIDs.count
        )
    }

    private func markConnectionPhase(
        _ phase: WatchConnectionPhase,
        for id: UUID,
        at date: Date = Date()
    ) {
        connectionPhases[id] = ConnectionPhaseState(phase: phase, startedAt: date)
        refreshConnectionDiagnostics()
    }

    private func refreshConnectionDiagnostics() {
        linkCount = announcedReadyLinks.count
        directLinkCount = Set(directPeerByLink.values).count
        knownPeripheralCount = peripherals.count
        connectingLinkCount = pendingConnectionIDs.count
        isScanning = centralManager?.isScanning == true
        let phaseCounts = Dictionary(grouping: connectionPhases.values, by: \.phase)
        connectionStageSummary = WatchConnectionPhase.allCases.compactMap { phase in
            guard let count = phaseCounts[phase]?.count, count > 0 else { return nil }
            return "\(phase.rawValue) \(count)"
        }.joined(separator: " · ")
        if connectionStageSummary.isEmpty { connectionStageSummary = "idle" }
    }

    private func adoptSystemConnectedPeripherals() {
        guard running, let centralManager, centralManager.state == .poweredOn else { return }
        let alreadyKnown = Set(peripherals.keys)
        let connected = centralManager.retrieveConnectedPeripherals(
            withServices: [Self.serviceUUID]
        )
        for peripheral in connected {
            peripherals[peripheral.identifier] = peripheral
            peripheralLastDiscoveredAt[peripheral.identifier] = Date()
            peripheral.delegate = self
            connectedAt[peripheral.identifier] = connectedAt[peripheral.identifier] ?? Date()
        }
        let newlyAdopted = connected.filter { !alreadyKnown.contains($0.identifier) }.count
        if newlyAdopted > 0 {
            lastBluetoothProgressAt = Date()
            log("adopted \(newlyAdopted) system Bluetooth link(s)")
        }
        refreshConnectionDiagnostics()
    }

    private func reconcileDiscoveryState() {
        guard running, let centralManager, centralManager.state == .poweredOn else {
            isScanning = false
            return
        }
        if shouldKeepDiscoveryArmed {
            startDiscoveryIfAllowed()
        } else if centralManager.isScanning {
            centralManager.stopScan()
            isScanning = false
            log(isAppInForeground
                ? "scan paused at \(WatchMeshRuntimePolicy.maximumPhysicalLinks)-link capacity"
                : "scan paused to preserve Bluetooth alert budget")
        }
        refreshConnectionDiagnostics()
    }

    private func startDiscoveryIfAllowed() {
        guard running, let centralManager, centralManager.state == .poweredOn,
              shouldKeepDiscoveryArmed,
              centralManager.isScanning == false else { return }
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        lastDiscoveryAt = Date()
        isScanning = true
        log(isAppInForeground
            ? "filtered discovery armed"
            : "filtered background discovery armed")
    }

    private func resumeKnownPeripherals() {
        guard running, centralManager?.state == .poweredOn else { return }
        let ordered = peripherals.values.sorted {
            let leftConnected = $0.state == .connected
            let rightConnected = $1.state == .connected
            if leftConnected != rightConnected { return leftConnected }
            return peripheralLastDiscoveredAt[$0.identifier, default: .distantPast]
                > peripheralLastDiscoveredAt[$1.identifier, default: .distantPast]
        }
        for peripheral in ordered {
            peripheral.delegate = self
            switch peripheral.state {
            case .connected:
                connectionRequestedAt.removeValue(forKey: peripheral.identifier)
                connectedAt[peripheral.identifier] = connectedAt[peripheral.identifier] ?? Date()
                if !announcedReadyLinks.contains(peripheral.identifier),
                   connectionPhases[peripheral.identifier] == nil {
                    markConnectionPhase(.services, for: peripheral.identifier)
                    peripheral.discoverServices([Self.serviceUUID])
                }
            case .disconnected:
                enqueueDiscoveryCandidate(
                    peripheral,
                    rssi: peripheralRSSI[peripheral.identifier] ?? -100,
                    advertisedPeerID: nil
                )
            default:
                break
            }
        }
        scheduleCandidateDrain()
        refreshConnectionDiagnostics()
    }

    @discardableResult
    private func requestConnection(_ peripheral: CBPeripheral) -> Bool {
        let id = peripheral.identifier
        guard running, centralManager?.state == .poweredOn,
              peripheral.state == .disconnected,
              connectionRequestedAt[id] == nil,
              WatchMeshRuntimePolicy.canStartConnection(
                physicalLinks: physicalConnectionIDs.count,
                pendingAttempts: pendingConnectionIDs.count,
                isAppInForeground: isAppInForeground
              ) else { return false }
        let now = Date()
        connectionRequestedAt[id] = now
        backgroundParkedLinks.remove(id)
        markConnectionPhase(.connecting, for: id, at: now)
        peripheralHistory.recordAttempt(id, at: now)
        centralManager.connect(peripheral)
        log("connecting \(id.uuidString.prefix(8))")
        refreshConnectionDiagnostics()
        reconcileDiscoveryState()
        return true
    }

    private func enqueueDiscoveryCandidate(
        _ peripheral: CBPeripheral,
        rssi: Int,
        advertisedPeerID: String?
    ) {
        let now = Date()
        if var existing = discoveryCandidates[peripheral.identifier] {
            existing.rssi = rssi
            existing.discoveredAt = now
            existing.advertisedPeerID = advertisedPeerID ?? existing.advertisedPeerID
            discoveryCandidates[peripheral.identifier] = existing
        } else {
            discoveryCandidates[peripheral.identifier] = DiscoveryCandidate(
                peripheral: peripheral,
                rssi: rssi,
                discoveredAt: now,
                advertisedPeerID: advertisedPeerID
            )
        }
    }

    private func scheduleCandidateDrain() {
        candidateDrainWorkItem?.cancel()
        if !isAppInForeground {
            drainDiscoveryCandidates()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.candidateDrainWorkItem = nil
            self?.drainDiscoveryCandidates()
        }
        candidateDrainWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WatchMeshRuntimePolicy.candidateCollectionInterval,
            execute: workItem
        )
    }

    private func drainDiscoveryCandidates(now: Date = Date()) {
        discoveryCandidates = discoveryCandidates.filter {
            now.timeIntervalSince($0.value.discoveredAt)
                <= WatchMeshRuntimePolicy.candidateRetentionInterval
                && $0.value.peripheral.state == .disconnected
        }
        guard WatchMeshRuntimePolicy.canStartConnection(
            physicalLinks: physicalConnectionIDs.count,
            pendingAttempts: pendingConnectionIDs.count,
            isAppInForeground: isAppInForeground
        ) else {
            refreshConnectionDiagnostics()
            return
        }

        let connectedPeerIDs = Set(directPeerByLink.values.map(\.id))
        let scores = discoveryCandidates.values.map { candidate in
            let history = peripheralHistory.snapshot(for: candidate.peripheral.identifier)
            let possiblePeerID = history.peerID ?? candidate.advertisedPeerID
            return WatchDiscoveryCandidateScore(
                id: candidate.peripheral.identifier,
                advertisedPeerIsConnected: possiblePeerID.map(connectedPeerIDs.contains) ?? false,
                previouslySuccessful: history.lastSuccessfulAt != nil,
                lastAttempt: history.lastAttemptAt,
                rssi: candidate.rssi,
                discoveredAt: candidate.discoveredAt
            )
        }

        for score in WatchMeshRuntimePolicy.rankCandidates(scores) {
            guard WatchMeshRuntimePolicy.canStartConnection(
                physicalLinks: physicalConnectionIDs.count,
                pendingAttempts: pendingConnectionIDs.count,
                isAppInForeground: isAppInForeground
            ) else { break }
            let history = peripheralHistory.snapshot(for: score.id)
            if WatchMeshRuntimePolicy.shouldSkipConnectionAttempt(
                consecutiveFailures: history.consecutiveFailures,
                lastFailureAt: history.lastFailureAt,
                lastSuccessfulAt: history.lastSuccessfulAt,
                now: now
            ) { continue }
            guard let candidate = discoveryCandidates.removeValue(forKey: score.id) else {
                continue
            }
            let trustedPeerID = history.peerID
            if trustedPeerID.map(connectedPeerIDs.contains) == true {
                log("skipping duplicate known peer \(score.id.uuidString.prefix(8))")
                continue
            }
            _ = requestConnection(candidate.peripheral)
        }
        refreshConnectionDiagnostics()
    }

    private func advertisedPeerID(
        from advertisementData: [String: Any]
    ) -> String? {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
                as? [CBUUID: Data],
              let identityBytes = serviceData[Self.serviceUUID],
              identityBytes.count >= 8 else { return nil }
        return identityBytes.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard running, central === centralManager else { return }
        if peripherals[peripheral.identifier]?.state == .connected { return }
        let now = Date()
        peripherals[peripheral.identifier] = peripheral
        peripheralLastDiscoveredAt[peripheral.identifier] = now
        peripheralRSSI[peripheral.identifier] = RSSI.intValue
        lastDiscoveryAt = now
        lastBluetoothProgressAt = now
        peripheral.delegate = self
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "bitchat"
        log("discovered \(name) rssi=\(RSSI)")
        guard RSSI.intValue >= WatchMeshRuntimePolicy.minimumCandidateRSSI else {
            log("ignoring weak candidate \(peripheral.identifier.uuidString.prefix(8)) rssi=\(RSSI)")
            refreshConnectionDiagnostics()
            return
        }
        enqueueDiscoveryCandidate(
            peripheral,
            rssi: RSSI.intValue,
            advertisedPeerID: advertisedPeerID(from: advertisementData)
        )
        scheduleCandidateDrain()
        refreshConnectionDiagnostics()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running, central === centralManager,
              peripherals[peripheral.identifier] === peripheral else { return }
        let now = Date()
        lastBluetoothProgressAt = now
        connectedAt[peripheral.identifier] = now
        retiredDuplicateLinks.remove(peripheral.identifier)
        recoveryVerificationWorkItems.removeValue(forKey: peripheral.identifier)?.cancel()
        reconnectWorkItems.removeValue(forKey: peripheral.identifier)?.cancel()
        connectionRequestedAt.removeValue(forKey: peripheral.identifier)
        let topologyChanged = removeDirectPeer(on: peripheral.identifier)
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        alertCharacteristics.removeValue(forKey: peripheral.identifier)
        announcedReadyLinks.remove(peripheral.identifier)
        pendingWrites.removeValue(forKey: peripheral.identifier)
        meshNotificationTimeoutWorkItems.removeValue(
            forKey: peripheral.identifier
        )?.cancel()
        meshNotificationRequests.removeValue(forKey: peripheral.identifier)
        meshNotificationFailureCounts.removeValue(forKey: peripheral.identifier)
        refreshConnectionDiagnostics()
        if topologyChanged { sendAnnounceToAllLinks() }
        log("connected \(peripheral.identifier.uuidString.prefix(8))")
        if !isAppInForeground, !backgroundDrainActive {
            enforceBackgroundConnectionBudget()
            guard peripheral.state == .connected else { return }
        }
        markConnectionPhase(.services, for: peripheral.identifier, at: now)
        peripheral.discoverServices([Self.serviceUUID])
        reconcileDiscoveryState()
        drainDiscoveryCandidates()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard running, central === centralManager,
              peripherals[peripheral.identifier] === peripheral else { return }
        connectionRequestedAt.removeValue(forKey: peripheral.identifier)
        connectionPhases.removeValue(forKey: peripheral.identifier)
        recoveryVerificationWorkItems.removeValue(forKey: peripheral.identifier)?.cancel()
        peripheralHistory.recordFailure(peripheral.identifier)
        lastRecoveryReason = "connect failed"
        log("connect failed \(peripheral.identifier.uuidString.prefix(8)): \(error?.localizedDescription ?? "unknown")")
        scheduleReconnect(peripheral)
        reconcileDiscoveryState()
        drainDiscoveryCandidates()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === centralManager,
              peripherals[peripheral.identifier] === peripheral else { return }
        connectionRequestedAt.removeValue(forKey: peripheral.identifier)
        connectionPhases.removeValue(forKey: peripheral.identifier)
        recoveryVerificationWorkItems.removeValue(forKey: peripheral.identifier)?.cancel()
        connectedAt.removeValue(forKey: peripheral.identifier)
        let topologyChanged = removeDirectPeer(on: peripheral.identifier)
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        alertCharacteristics.removeValue(forKey: peripheral.identifier)
        announcedReadyLinks.remove(peripheral.identifier)
        pendingWrites.removeValue(forKey: peripheral.identifier)
        meshNotificationTimeoutWorkItems.removeValue(
            forKey: peripheral.identifier
        )?.cancel()
        meshNotificationRequests.removeValue(forKey: peripheral.identifier)
        meshNotificationFailureCounts.removeValue(forKey: peripheral.identifier)
        refreshConnectionDiagnostics()
        log("disconnected \(peripheral.identifier.uuidString.prefix(8))")
        guard running else { return }
        if retiredDuplicateLinks.remove(peripheral.identifier) != nil {
            log("duplicate link retired")
            reconcileDiscoveryState()
            drainDiscoveryCandidates()
            return
        }
        if backgroundParkedLinks.remove(peripheral.identifier) != nil {
            log("background relay parked \(peripheral.identifier.uuidString.prefix(8))")
            if isAppInForeground { scheduleReconnect(peripheral) }
            reconcileDiscoveryState()
            drainDiscoveryCandidates()
            return
        }
        if topologyChanged { sendAnnounceToAllLinks() }
        refreshAnnounceHeartbeat()
        scheduleReconnect(peripheral)
        reconcileDiscoveryState()
        drainDiscoveryCandidates()
    }

    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        guard running else { return }
        let id = peripheral.identifier
        reconnectWorkItems.removeValue(forKey: id)?.cancel()
        let attempt = reconnectAttempts[id, default: 0] + 1
        reconnectAttempts[id] = attempt
        // A nonzero delay rides a DispatchQueue timer, which cannot fire
        // while the process is suspended. Background retries are handed to
        // Core Bluetooth immediately as system-owned connection requests;
        // only foreground retries use bounded backoff.
        let delay = WatchMeshRuntimePolicy.reconnectDelay(
            isAppInForeground: isAppInForeground,
            attempt: attempt
        )
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self else { return }
            self.reconnectWorkItems.removeValue(forKey: id)
            guard let peripheral, self.running,
                  self.centralManager?.state == .poweredOn,
                  self.peripherals[id] === peripheral,
                  peripheral.state == .disconnected else { return }
            self.enqueueDiscoveryCandidate(
                peripheral,
                rssi: self.peripheralRSSI[id] ?? -100,
                advertisedPeerID: nil
            )
            self.scheduleCandidateDrain()
        }
        reconnectWorkItems[id] = workItem
        if delay == 0 {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}

extension WatchBLEController: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        let uuid = peripheral.identifier
        guard running, peripherals[uuid] === peripheral,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else {
            return
        }

        // The advertising phone may rebuild its GATT database after an iOS
        // restoration or app upgrade. Every characteristic from the old
        // service is invalid at this point; keeping those references makes a
        // connected link look healthy while all future subscriptions/writes
        // silently target a dead service.
        writableCharacteristics.removeValue(forKey: uuid)
        alertCharacteristics.removeValue(forKey: uuid)
        announcedReadyLinks.remove(uuid)
        pendingWrites.removeValue(forKey: uuid)
        meshNotificationTimeoutWorkItems.removeValue(forKey: uuid)?.cancel()
        meshNotificationRequests.removeValue(forKey: uuid)
        meshNotificationFailureCounts.removeValue(forKey: uuid)
        markConnectionPhase(.services, for: uuid)
        log("peer service changed; rediscovering \(uuid.uuidString.prefix(8))")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard running, peripherals[peripheral.identifier] === peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failLink(peripheral, reason: error?.localizedDescription ?? "bitchat service not found")
            return
        }
        lastBluetoothProgressAt = Date()
        markConnectionPhase(.characteristics, for: peripheral.identifier)
        peripheral.discoverCharacteristics(
            [Self.characteristicUUID, Self.alertCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard running, peripherals[peripheral.identifier] === peripheral else { return }
        guard error == nil,
              let meshCharacteristic = service.characteristics?.first(
                where: { $0.uuid == Self.characteristicUUID }
              ),
              meshCharacteristic.properties.contains(.writeWithoutResponse),
              meshCharacteristic.properties.contains(.notify)
                || meshCharacteristic.properties.contains(.indicate) else {
            failLink(
                peripheral,
                reason: error?.localizedDescription ?? "incompatible characteristic"
            )
            return
        }
        let uuid = peripheral.identifier
        lastBluetoothProgressAt = Date()
        writableCharacteristics[uuid] = meshCharacteristic
        meshNotificationTimeoutWorkItems.removeValue(forKey: uuid)?.cancel()
        meshNotificationRequests.removeValue(forKey: uuid)
        meshNotificationFailureCounts.removeValue(forKey: uuid)
        markConnectionPhase(.subscribing, for: uuid)
        refreshConnectionDiagnostics()

        let alertCharacteristic = service.characteristics?.first(where: {
            $0.uuid == Self.alertCharacteristicUUID
                && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
        })
        if let alertCharacteristic {
            alertCharacteristics[uuid] = alertCharacteristic
            peripheral.setNotifyValue(true, for: alertCharacteristic)
            _ = requestMeshNotificationState(
                desiredMeshNotificationState(for: uuid),
                for: peripheral,
                characteristic: meshCharacteristic
            )
            log("enabling dedicated alert lane \(uuid.uuidString.prefix(8))")
        } else {
            // Older iOS/Android peers remain interoperable. They use the
            // original mixed-traffic subscription until upgraded.
            _ = requestMeshNotificationState(
                true,
                for: peripheral,
                characteristic: meshCharacteristic
            )
            log("peer has no alert lane; using legacy mesh notifications")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard running, peripherals[peripheral.identifier] === peripheral else { return }
        let uuid = peripheral.identifier
        if characteristic.uuid == Self.alertCharacteristicUUID {
            guard alertCharacteristics[uuid] === characteristic else { return }
            guard error == nil, characteristic.isNotifying else {
                alertCharacteristics.removeValue(forKey: uuid)
                if backgroundParkedLinks.contains(uuid) {
                    log("alert lane quiet for parked link \(uuid.uuidString.prefix(8))")
                    return
                }
                log("alert lane unavailable; falling back to full mesh")
                if let mesh = writableCharacteristics[uuid] {
                    _ = requestMeshNotificationState(
                        true,
                        for: peripheral,
                        characteristic: mesh
                    )
                }
                return
            }
            markLinkReady(peripheral)
            return
        }
        guard characteristic.uuid == Self.characteristicUUID else { return }
        guard writableCharacteristics[uuid] === characteristic else { return }
        meshNotificationTimeoutWorkItems.removeValue(forKey: uuid)?.cancel()
        let completedTarget = meshNotificationRequests.removeValue(forKey: uuid)
        let desiredState = desiredMeshNotificationState(for: uuid)
        if let error {
            if characteristic.isNotifying == desiredState {
                meshNotificationFailureCounts.removeValue(forKey: uuid)
            } else {
                let failures = meshNotificationFailureCounts[uuid, default: 0] + 1
                meshNotificationFailureCounts[uuid] = failures
                log(
                    "mesh subscription transition failed "
                        + "target=\(desiredState) attempt=\(failures): "
                        + error.localizedDescription
                )
                guard failures < 2 else {
                    failLink(
                        peripheral,
                        reason: "mesh subscription could not converge: "
                            + error.localizedDescription
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak peripheral, weak characteristic] in
                    guard let self, let peripheral, let characteristic,
                          self.running,
                          self.peripherals[uuid] === peripheral,
                          self.writableCharacteristics[uuid] === characteristic else {
                        return
                    }
                    _ = self.requestMeshNotificationState(
                        self.desiredMeshNotificationState(for: uuid),
                        for: peripheral,
                        characteristic: characteristic
                    )
                }
                return
            }
        } else {
            meshNotificationFailureCounts.removeValue(forKey: uuid)
        }

        guard characteristic.isNotifying == desiredState else {
            log(
                "mesh subscription callback target=\(completedTarget.map { String($0) } ?? "external") "
                    + "state=\(characteristic.isNotifying); converging to \(desiredState)"
            )
            _ = requestMeshNotificationState(
                desiredState,
                for: peripheral,
                characteristic: characteristic
            )
            return
        }

        if characteristic.isNotifying {
            markLinkReady(peripheral)
            // setNotifyValue is asynchronous. Requesting catch-up during a
            // scene transition can race this callback and lose the response.
            // Background drains stay rate-limited: every wake would otherwise
            // force a per-link sync flood that re-arms the alert oscillation.
            requestPublicSyncIfNeeded(on: uuid, force: isAppInForeground)
            requestStalledFragments()
        } else {
            log("mesh lane quiet \(uuid.uuidString.prefix(8))")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = peripheral.identifier
        guard running, peripherals[uuid] === peripheral else { return }
        let arrivedOnMesh = characteristic.uuid == Self.characteristicUUID
            && writableCharacteristics[uuid] === characteristic
        let arrivedOnAlert = characteristic.uuid == Self.alertCharacteristicUUID
            && alertCharacteristics[uuid] === characteristic
        guard arrivedOnMesh || arrivedOnAlert else { return }
        if let error {
            recordBluetoothAlertError(error)
            bluetoothAlertGate.signal()
            return
        }
        guard let data = characteristic.value, !data.isEmpty else {
            log("Bluetooth alert delivered no data")
            bluetoothAlertGate.signal()
            return
        }
        lastBluetoothProgressAt = Date()
        rxBytes += data.count
        if arrivedOnAlert, let signal = WatchTimelyAlertSignal.decode(data) {
            let signalID = String(
                format: "%02x-%016llx",
                signal.type,
                signal.timestamp
            )
            pendingTimelyAlertSignalIDs.insert(signalID)
            backgroundAlertState = "catching up"
            log("Bluetooth message signal \(signalID)")
            beginDelegateDrivenDrainIfNeeded()
            return
        }
        if arrivedOnAlert {
            // Short handshakes and encrypted DMs can fit directly on the
            // alert characteristic. Reopen the main lane before processing
            // them so any response and the packet(s) that follow can complete
            // inside the system-granted runtime window.
            beginDelegateDrivenDrainIfNeeded()
        }
        handleIncomingData(data, from: peripheral.identifier)
    }

    private func markLinkReady(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier
        guard peripherals[uuid] === peripheral else { return }
        let now = Date()
        lastBluetoothProgressAt = now
        connectionPhases.removeValue(forKey: uuid)
        connectionRequestedAt.removeValue(forKey: uuid)
        // A radio connection is not a usable mesh link. Preserve backoff
        // through service discovery and subscription failures.
        reconnectAttempts.removeValue(forKey: uuid)
        peripheralHistory.recordSuccess(uuid, at: now)
        let becameReady = announcedReadyLinks.insert(uuid).inserted
        consecutivePhaseTimeouts = 0
        refreshConnectionDiagnostics()
        reconcileDiscoveryState()
        guard becameReady else { return }
        log("link ready mtu=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        sendAnnounce(to: [uuid])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.running,
                  self.peripherals[uuid] === peripheral,
                  self.announcedReadyLinks.contains(uuid),
                  self.writableCharacteristics[uuid]?.isNotifying == true else { return }
            self.requestPublicSyncIfNeeded(on: uuid, force: self.isAppInForeground)
        }
        refreshAnnounceHeartbeat()
        drainDiscoveryCandidates()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripherals[peripheral.identifier] === peripheral else { return }
        if let error { log("write error: \(error.localizedDescription)") }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripherals[peripheral.identifier] === peripheral else { return }
        drainPendingWrites(for: peripheral)
    }

    private func failLink(_ peripheral: CBPeripheral, reason: String) {
        guard peripherals[peripheral.identifier] === peripheral else { return }
        peripheralHistory.recordFailure(peripheral.identifier)
        let topologyChanged = removeDirectPeer(on: peripheral.identifier)
        connectionRequestedAt.removeValue(forKey: peripheral.identifier)
        connectionPhases.removeValue(forKey: peripheral.identifier)
        recoveryVerificationWorkItems.removeValue(forKey: peripheral.identifier)?.cancel()
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        alertCharacteristics.removeValue(forKey: peripheral.identifier)
        announcedReadyLinks.remove(peripheral.identifier)
        pendingWrites.removeValue(forKey: peripheral.identifier)
        meshNotificationTimeoutWorkItems.removeValue(
            forKey: peripheral.identifier
        )?.cancel()
        meshNotificationRequests.removeValue(forKey: peripheral.identifier)
        meshNotificationFailureCounts.removeValue(forKey: peripheral.identifier)
        refreshConnectionDiagnostics()
        lastRecoveryReason = reason
        log("link failed \(peripheral.identifier.uuidString.prefix(8)): \(reason)")
        if topologyChanged { sendAnnounceToAllLinks() }
        refreshAnnounceHeartbeat()
        centralManager?.cancelPeripheralConnection(peripheral)
        reconcileDiscoveryState()
    }

    private func recordBluetoothAlertError(_ error: Error) {
        let nsError = error as NSError
        let code = CBError.Code(rawValue: nsError.code)
        switch code {
        case .leGattNearBackgroundNotificationLimit:
            backgroundAlertState = "near limit"
            log("Bluetooth background alert budget is nearly exhausted")
        case .leGattExceededBackgroundNotificationLimit:
            backgroundAlertState = "limit exceeded"
            log("Bluetooth background alert budget exhausted; open bitchat to reset it")
        default:
            backgroundAlertState = "error"
            log("Bluetooth value update failed: \(error.localizedDescription)")
        }
    }
}
