//
// WatchLiveVoice.swift
// bitchat
//
// watchOS capture, playback, and assembly for the iOS-compatible hybrid
// push-to-talk protocol. Wire primitives and AAC codec code are compiled from
// the same sources as the phone target to prevent the two implementations
// from drifting.
//

import AVFoundation
import BitFoundation
import Foundation

/// Watch-local mirror of the live-voice transport limits. `VoiceBurstPacket`
/// uses the content budget as its default packetizer size when compiled into
/// this target.
enum TransportConfig {
    static let pttMaxBurstContentBytes = 210
    static let pttJitterBufferSeconds: TimeInterval = 0.35
    static let pttJitterDeadlineSeconds: TimeInterval = 0.5
    static let pttBurstEndTimeoutSeconds: TimeInterval = 3
    static let pttMaxConcurrentAssemblies = 8
    static let pttMaxBurstBytes = 384 * 1024
    static let pttFinishedBurstRegistrySeconds: TimeInterval = 600
    static let pttInboundMaxBytesPerSecond = 6_000
    static let pttPublicFrameMaxAgeSeconds: TimeInterval = 30
}

enum WatchVoiceBurstScope: Hashable {
    case directMessage
    case publicMesh
}

// MARK: - Shared watch audio-session ownership

/// Keeps live capture and playback from deactivating `AVAudioSession` out
/// from underneath one another when a watch talks and receives at once.
final class WatchLiveAudioSession {
    static let shared = WatchLiveAudioSession()

    private var captureOwners = 0
    private var playbackOwners = 0

    private init() {}

    func acquireCapture() throws {
        captureOwners += 1
        do {
            try activate()
        } catch {
            captureOwners -= 1
            throw error
        }
    }

    func releaseCapture() {
        captureOwners = max(0, captureOwners - 1)
        deactivateIfIdle()
    }

    func acquirePlayback() throws {
        playbackOwners += 1
        do {
            try activate()
        } catch {
            playbackOwners -= 1
            throw error
        }
    }

    func releasePlayback() {
        playbackOwners = max(0, playbackOwners - 1)
        deactivateIfIdle()
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
    }

    private func deactivateIfIdle() {
        guard captureOwners == 0, playbackOwners == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Live capture

/// Produces raw AAC frames while writing the same PCM stream to a finalized
/// `.m4a`. Mutable codec/file state is confined to `queue`.
final class WatchPTTCaptureEngine {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(
        label: "chat.bitchat.watch.ptt.capture",
        qos: .userInitiated
    )

    private var resampler: PTTInputResampler?
    private var encoder: PTTFrameEncoder?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var encodedFrameCount = 0
    private var running = false
    private var ownsAudioSession = false
    private var tapInstalled = false

    var onFrames: (([Data]) -> Void)?
    var onLevel: ((Float) -> Void)?

    enum CaptureError: Error {
        case inputUnavailable
        case audioSetupFailed
    }

    func start(outputURL: URL) throws {
        try WatchLiveAudioSession.shared.acquireCapture()
        ownsAudioSession = true

        do {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw CaptureError.inputUnavailable
            }
            guard let resampler = PTTInputResampler(inputFormat: inputFormat),
                  let encoder = PTTFrameEncoder(),
                  let pcmFormat = PTTAudioFormat.pcmFormat else {
                throw CaptureError.audioSetupFailed
            }
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: PTTAudioFormat.voiceNoteFileSettings,
                commonFormat: pcmFormat.commonFormat,
                interleaved: pcmFormat.isInterleaved
            )

            queue.sync {
                self.resampler = resampler
                self.encoder = encoder
                self.file = file
                self.outputURL = outputURL
                encodedFrameCount = 0
                running = true
            }

            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.queue.async { [weak self] in
                    self?.process(buffer)
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            queue.sync { teardown(deleteFile: true) }
            releaseAudioSession()
            throw error
        }
    }

    func stop() -> (url: URL?, encodedFrames: Int) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        let result: (URL?, Int) = queue.sync {
            let result = (outputURL, encodedFrameCount)
            teardown(deleteFile: false)
            return result
        }
        releaseAudioSession()
        return result
    }

    func cancel() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        queue.sync { teardown(deleteFile: true) }
        releaseAudioSession()
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard running, let resampler, let encoder,
              let pcm = resampler.resample(input) else { return }
        do {
            try file?.write(from: pcm)
        } catch {
            // Live delivery can continue even when final-note persistence
            // fails; stop writing but keep encoding frames.
            file = nil
        }
        let frames = encoder.encode(pcm)
        encodedFrameCount += frames.count
        if !frames.isEmpty { onFrames?(frames) }
        onLevel?(Self.level(from: input))
    }

    private func teardown(deleteFile: Bool) {
        running = false
        file = nil // finalizes the MPEG-4 container
        encoder = nil
        resampler = nil
        encodedFrameCount = 0
        if deleteFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        WatchLiveAudioSession.shared.releaseCapture()
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0 else { return 0.08 }
        let count = Int(buffer.frameLength)
        let step = max(1, count / 512)
        var sum: Float = 0
        var samples = 0
        for index in stride(from: 0, to: count, by: step) {
            let value = channel[index]
            sum += value * value
            samples += 1
        }
        guard samples > 0 else { return 0.08 }
        return max(0.08, min(1, sqrt(sum / Float(samples)) * 5))
    }
}

// MARK: - Live playback

/// Incremental AAC player with a small startup jitter buffer. The coordinator
/// owns one instance per audible burst and continues persisting audio even if
/// playback cannot start.
final class WatchPTTBurstPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder: PTTFrameDecoder
    private var queued: [AVAudioPCMBuffer] = []
    private var queuedDuration: TimeInterval = 0
    private var pendingBuffers = 0
    private var started = false
    private var finished = false
    private var stopped = false
    private var ownsAudioSession = false
    private var deadline: DispatchWorkItem?

    var onStopped: (() -> Void)?

    init?() {
        guard let format = PTTAudioFormat.pcmFormat,
              let decoder = PTTFrameDecoder() else { return nil }
        self.decoder = decoder
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let deadline = DispatchWorkItem { [weak self] in
            self?.startIfReady(force: true)
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TransportConfig.pttJitterDeadlineSeconds,
            execute: deadline
        )
    }

    deinit {
        deadline?.cancel()
        node.stop()
        engine.stop()
        releaseAudioSession()
    }

    func enqueue(_ frames: [Data]) {
        guard !stopped else { return }
        for frame in frames {
            guard let buffer = decoder.decode(frame) else { continue }
            if started {
                schedule(buffer)
            } else {
                queued.append(buffer)
                queuedDuration += Double(buffer.frameLength) / PTTAudioFormat.sampleRate
            }
        }
        startIfReady(force: false)
    }

    func finishAfterDrain() {
        finished = true
        startIfReady(force: true)
        stopIfDrained()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel()
        deadline = nil
        queued.removeAll()
        pendingBuffers = 0
        node.stop()
        engine.stop()
        releaseAudioSession()
        let callback = onStopped
        onStopped = nil
        callback?()
    }

    private func startIfReady(force: Bool) {
        guard !started, !stopped, !queued.isEmpty,
              force || queuedDuration >= TransportConfig.pttJitterBufferSeconds else { return }
        do {
            try WatchLiveAudioSession.shared.acquirePlayback()
            ownsAudioSession = true
            engine.prepare()
            try engine.start()
            node.play()
            started = true
            deadline?.cancel()
            deadline = nil
            let buffers = queued
            queued.removeAll()
            queuedDuration = 0
            for buffer in buffers { schedule(buffer) }
        } catch {
            stop()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        pendingBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.stopIfDrained()
            }
        }
    }

    private func stopIfDrained() {
        guard finished, queued.isEmpty, pendingBuffers == 0 else { return }
        stop()
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        WatchLiveAudioSession.shared.releasePlayback()
    }
}

// MARK: - Inbound burst assembly

protocol WatchLiveVoiceCoordinatorDelegate: AnyObject {
    func liveVoiceShouldAutoplay(from peerID: PeerID, scope: WatchVoiceBurstScope) -> Bool
    func liveVoiceUpsert(_ message: WatchChatMessage, peerID: PeerID?)
    func liveVoiceRemove(messageID: String, peerID: PeerID?)
    func liveVoiceDidStartDirectMessage(
        id: String,
        from peerID: PeerID,
        sender: String
    )
    func liveVoiceDidAdoptFinalizedDirectMessage(
        oldMessageID: String,
        message: WatchChatMessage,
        from peerID: PeerID
    )
    func liveVoiceSetPublicTalker(_ nickname: String?)
    func liveVoiceLog(_ message: String)
}

/// Reorders, plays, and progressively persists incoming voice bursts. A
/// finalized `.m4a` carrying the same burst ID is adopted into the existing
/// row so watchOS and iOS never show duplicate voice notes.
final class WatchLiveVoiceCoordinator {
    private struct Key: Hashable {
        let peerID: PeerID
        let scope: WatchVoiceBurstScope
        let burstID: Data
    }

    private final class Assembly {
        let key: Key
        let nickname: String
        let messageID: String
        let timestamp: Date
        let liveURL: URL
        var fileHandle: FileHandle?
        var buffered: [UInt16: [Data]] = [:]
        var nextSequence: UInt16 = 1
        var deliveredFrames = 0
        var receivedBytes = 0
        let firstPacketAt = Date()
        var endInfo: (packets: UInt16, durationMs: UInt32)?
        var gapSince: Date?
        var idleTimeout: DispatchWorkItem?
        var gapRedrain: DispatchWorkItem?
        var player: WatchPTTBurstPlayer?

        init(
            key: Key,
            nickname: String,
            messageID: String,
            timestamp: Date,
            liveURL: URL,
            fileHandle: FileHandle
        ) {
            self.key = key
            self.nickname = nickname
            self.messageID = messageID
            self.timestamp = timestamp
            self.liveURL = liveURL
            self.fileHandle = fileHandle
        }
    }

    private struct FinishedBurst {
        let messageID: String
        let timestamp: Date
        let fallbackURL: URL
        let expiresAt: Date
    }

    private static let gapSkipSeconds: TimeInterval = 0.5
    private static let finishedBurstCap = 32

    private weak var delegate: (any WatchLiveVoiceCoordinatorDelegate)?
    private var assemblies: [Key: Assembly] = [:]
    private var finishedBursts: [Key: FinishedBurst] = [:]
    private var drainingPlayers: [ObjectIdentifier: WatchPTTBurstPlayer] = [:]

    init(delegate: any WatchLiveVoiceCoordinatorDelegate) {
        self.delegate = delegate
        sweepStaleCaptures()
    }

    func handle(
        _ payload: Data,
        from peerID: PeerID,
        scope: WatchVoiceBurstScope,
        nickname: String,
        timestamp: Date
    ) {
        guard let packet = VoiceBurstPacket.decode(payload) else {
            delegate?.liveVoiceLog("PTT reject: malformed frame from \(peerID.id.prefix(8))")
            return
        }
        let key = Key(peerID: peerID, scope: scope, burstID: packet.burstID)
        if let assembly = assemblies[key] {
            apply(packet, to: assembly)
            return
        }

        switch packet.kind {
        case .start, .frames:
            guard assemblies.count < TransportConfig.pttMaxConcurrentAssemblies,
                  let assembly = makeAssembly(
                    key: key,
                    nickname: nickname,
                    timestamp: timestamp
                  ) else { return }
            assemblies[key] = assembly
            updatePublicTalker()
            apply(packet, to: assembly)
        case .end, .canceled:
            break
        }
    }

    /// Returns true when `attachment` replaced an already-created live row.
    func absorbFinalizedVoiceNote(
        attachment: WatchMediaAttachment,
        wireFileName: String,
        messageID: String,
        from peerID: PeerID,
        nickname: String,
        timestamp: Date,
        isPrivate: Bool
    ) -> Bool {
        guard let burstID = Self.burstID(fromVoiceFileName: wireFileName) else {
            return false
        }
        let scope: WatchVoiceBurstScope = isPrivate ? .directMessage : .publicMesh
        let key = Key(peerID: peerID, scope: scope, burstID: burstID)
        if let assembly = assemblies[key] { finalize(assembly) }
        pruneFinishedBursts()
        guard let finished = finishedBursts.removeValue(forKey: key) else {
            return false
        }

        let adoptedID = isPrivate ? messageID : finished.messageID
        let message = WatchChatMessage(
            id: adoptedID,
            sender: nickname,
            senderPeerID: peerID,
            content: attachment.fileName,
            timestamp: finished.timestamp,
            isSelf: false,
            isPrivate: isPrivate,
            conversationPeerID: isPrivate ? peerID : nil,
            status: "",
            media: attachment
        )
        try? FileManager.default.removeItem(at: finished.fallbackURL)

        if isPrivate {
            delegate?.liveVoiceDidAdoptFinalizedDirectMessage(
                oldMessageID: finished.messageID,
                message: message,
                from: peerID
            )
        } else {
            delegate?.liveVoiceUpsert(message, peerID: nil)
        }
        return true
    }

    func setAppInForeground(_ foreground: Bool) {
        guard !foreground else { return }
        for assembly in assemblies.values {
            assembly.player?.stop()
            assembly.player = nil
        }
        for player in Array(drainingPlayers.values) { player.stop() }
        drainingPlayers.removeAll()
    }

    func reset() {
        // A normal mesh stop is not a panic wipe. Preserve any audio already
        // received as a replayable fallback; only discard the short-lived
        // matching registry used to adopt a later `.m4a`.
        for assembly in Array(assemblies.values) { finalize(assembly) }
        finishedBursts.removeAll()
        updatePublicTalker()
    }

    private func makeAssembly(
        key: Key,
        nickname: String,
        timestamp: Date
    ) -> Assembly? {
        guard let liveURL = makeLiveURL(for: key) else { return nil }
        FileManager.default.createFile(atPath: liveURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: liveURL) else {
            try? FileManager.default.removeItem(at: liveURL)
            return nil
        }
        let messageID = "voice-live-\(key.peerID.id)-\(scopeTag(key.scope))-\(key.burstID.hexEncodedString())"
        let attachment = WatchMediaAttachment(
            url: liveURL,
            fileName: liveURL.lastPathComponent,
            mimeType: "audio/aac",
            byteCount: 0,
            isLive: true
        )
        let message = WatchChatMessage(
            id: messageID,
            sender: nickname,
            senderPeerID: key.peerID,
            content: attachment.fileName,
            timestamp: timestamp,
            isSelf: false,
            isPrivate: key.scope == .directMessage,
            conversationPeerID: key.scope == .directMessage ? key.peerID : nil,
            status: "",
            media: attachment
        )
        let assembly = Assembly(
            key: key,
            nickname: nickname,
            messageID: messageID,
            timestamp: timestamp,
            liveURL: liveURL,
            fileHandle: handle
        )
        if delegate?.liveVoiceShouldAutoplay(from: key.peerID, scope: key.scope) == true {
            assembly.player = WatchPTTBurstPlayer()
        }
        delegate?.liveVoiceUpsert(
            message,
            peerID: key.scope == .directMessage ? key.peerID : nil
        )
        if key.scope == .directMessage {
            delegate?.liveVoiceDidStartDirectMessage(
                id: messageID,
                from: key.peerID,
                sender: nickname
            )
        }
        delegate?.liveVoiceLog("PTT start ← \(nickname)")
        return assembly
    }

    private func apply(_ packet: VoiceBurstPacket, to assembly: Assembly) {
        assembly.receivedBytes += packet.encode().count
        let elapsed = Date().timeIntervalSince(assembly.firstPacketAt)
        guard assembly.receivedBytes <= TransportConfig.pttMaxBurstBytes,
              assembly.receivedBytes
                <= TransportConfig.pttInboundMaxBytesPerSecond * Int(elapsed + 2) else {
            delegate?.liveVoiceLog("PTT stopped: inbound rate limit")
            finalize(assembly)
            return
        }
        rescheduleIdleTimeout(for: assembly)

        switch packet.kind {
        case .start(let codec):
            if codec != .aacLC16kMono { cancel(assembly) }
        case .frames(let frames):
            guard packet.seq >= assembly.nextSequence,
                  assembly.buffered[packet.seq] == nil else { return }
            assembly.buffered[packet.seq] = frames
            drainInOrder(assembly)
        case .end(let packets, let durationMs):
            assembly.endInfo = (packets, durationMs)
            drainInOrder(assembly)
            finalizeIfComplete(assembly)
        case .canceled:
            cancel(assembly)
        }
    }

    private func drainInOrder(_ assembly: Assembly) {
        while true {
            if let frames = assembly.buffered.removeValue(forKey: assembly.nextSequence) {
                deliver(frames, to: assembly)
                assembly.nextSequence &+= 1
                assembly.gapSince = nil
                continue
            }
            guard !assembly.buffered.isEmpty else {
                assembly.gapSince = nil
                return
            }
            if let gapSince = assembly.gapSince {
                guard Date().timeIntervalSince(gapSince) >= Self.gapSkipSeconds,
                      let next = assembly.buffered.keys.min() else { return }
                assembly.nextSequence = next
                assembly.gapSince = nil
            } else {
                assembly.gapSince = Date()
                scheduleGapRedrain(for: assembly)
                return
            }
        }
    }

    private func deliver(_ frames: [Data], to assembly: Assembly) {
        for frame in frames {
            do {
                try assembly.fileHandle?.write(contentsOf: ADTSFramer.frame(frame))
            } catch {
                try? assembly.fileHandle?.close()
                assembly.fileHandle = nil
            }
        }
        assembly.deliveredFrames += frames.count
        assembly.player?.enqueue(frames)
    }

    private func finalizeIfComplete(_ assembly: Assembly) {
        guard let end = assembly.endInfo,
              assembly.nextSequence > end.packets else { return }
        finalize(assembly)
    }

    private func finalize(_ assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        assembly.gapRedrain?.cancel()
        while let sequence = assembly.buffered.keys.min(),
              let frames = assembly.buffered.removeValue(forKey: sequence) {
            assembly.nextSequence = sequence &+ 1
            deliver(frames, to: assembly)
        }
        try? assembly.fileHandle?.close()
        assembly.fileHandle = nil
        assemblies.removeValue(forKey: assembly.key)
        updatePublicTalker()

        guard assembly.deliveredFrames > 0 else {
            delegate?.liveVoiceRemove(
                messageID: assembly.messageID,
                peerID: assembly.key.scope == .directMessage ? assembly.key.peerID : nil
            )
            try? FileManager.default.removeItem(at: assembly.liveURL)
            assembly.player?.stop()
            return
        }

        if let player = assembly.player {
            let id = ObjectIdentifier(player)
            drainingPlayers[id] = player
            player.onStopped = { [weak self] in
                self?.drainingPlayers.removeValue(forKey: id)
            }
            player.finishAfterDrain()
        }
        let fallbackURL = promote(assembly.liveURL, key: assembly.key)
        let byteCount = (try? fallbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let attachment = WatchMediaAttachment(
            url: fallbackURL,
            fileName: fallbackURL.lastPathComponent,
            mimeType: "audio/aac",
            byteCount: byteCount,
            isLive: false
        )
        let message = WatchChatMessage(
            id: assembly.messageID,
            sender: assembly.nickname,
            senderPeerID: assembly.key.peerID,
            content: attachment.fileName,
            timestamp: assembly.timestamp,
            isSelf: false,
            isPrivate: assembly.key.scope == .directMessage,
            conversationPeerID: assembly.key.scope == .directMessage ? assembly.key.peerID : nil,
            status: "",
            media: attachment
        )
        delegate?.liveVoiceUpsert(
            message,
            peerID: assembly.key.scope == .directMessage ? assembly.key.peerID : nil
        )

        pruneFinishedBursts()
        finishedBursts[assembly.key] = FinishedBurst(
            messageID: assembly.messageID,
            timestamp: assembly.timestamp,
            fallbackURL: fallbackURL,
            expiresAt: Date().addingTimeInterval(
                TransportConfig.pttFinishedBurstRegistrySeconds
            )
        )
        delegate?.liveVoiceLog("PTT finish ← \(assembly.nickname)")
    }

    private func cancel(_ assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        assembly.gapRedrain?.cancel()
        assembly.player?.stop()
        try? assembly.fileHandle?.close()
        assembly.fileHandle = nil
        assemblies.removeValue(forKey: assembly.key)
        delegate?.liveVoiceRemove(
            messageID: assembly.messageID,
            peerID: assembly.key.scope == .directMessage ? assembly.key.peerID : nil
        )
        try? FileManager.default.removeItem(at: assembly.liveURL)
        updatePublicTalker()
    }

    private func rescheduleIdleTimeout(for assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        let key = assembly.key
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.assemblies[key] else { return }
            self.finalize(current)
        }
        assembly.idleTimeout = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TransportConfig.pttBurstEndTimeoutSeconds,
            execute: work
        )
    }

    private func scheduleGapRedrain(for assembly: Assembly) {
        assembly.gapRedrain?.cancel()
        let key = assembly.key
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.assemblies[key] else { return }
            self.drainInOrder(current)
            self.finalizeIfComplete(current)
        }
        assembly.gapRedrain = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.gapSkipSeconds + 0.05,
            execute: work
        )
    }

    private func updatePublicTalker() {
        let talker = assemblies.values.first {
            $0.key.scope == .publicMesh
        }?.nickname
        delegate?.liveVoiceSetPublicTalker(talker)
    }

    private func pruneFinishedBursts() {
        let now = Date()
        finishedBursts = finishedBursts.filter { $0.value.expiresAt > now }
        while finishedBursts.count >= Self.finishedBurstCap,
              let oldest = finishedBursts.min(by: {
                $0.value.expiresAt < $1.value.expiresAt
              }) {
            finishedBursts.removeValue(forKey: oldest.key)
        }
    }

    private func makeLiveURL(for key: Key) -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = documents.appendingPathComponent("ReceivedMedia", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        let name = "voice_live_\(key.burstID.hexEncodedString())_\(key.peerID.id)_\(scopeTag(key.scope)).aac"
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func promote(_ liveURL: URL, key: Key) -> URL {
        let name = "voice_\(key.burstID.hexEncodedString())_\(key.peerID.id)_\(scopeTag(key.scope)).aac"
        let destination = liveURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: liveURL, to: destination)
            return destination
        } catch {
            return liveURL
        }
    }

    private func sweepStaleCaptures() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: documents.appendingPathComponent("ReceivedMedia", isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("voice_live_") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func burstID(fromVoiceFileName fileName: String) -> Data? {
        guard fileName.hasPrefix("voice_") else { return nil }
        let hex = String(fileName.dropFirst("voice_".count).prefix(16))
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        return Data(hexString: hex)
    }

    private func scopeTag(_ scope: WatchVoiceBurstScope) -> String {
        scope == .directMessage ? "dm" : "mesh"
    }
}
