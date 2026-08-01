//
// WatchMedia.swift
// bitchat
//

import AVFoundation
import BitFoundation
import Combine
import Foundation
import WatchKit

enum WatchMediaKind: Equatable {
    case image
    case audio
    case file
}

struct WatchMediaAttachment: Codable, Equatable {
    let url: URL
    let fileName: String
    let mimeType: String
    let byteCount: Int
    var isLive = false

    var kind: WatchMediaKind {
        if mimeType.lowercased().hasPrefix("image/") { return .image }
        if mimeType.lowercased().hasPrefix("audio/") { return .audio }
        return .file
    }
}

enum WatchMediaStore {
    private static let maximumStoredBytes = 32 * 1_024 * 1_024
    private static let maximumStoredFiles = 256

    struct RetentionCandidate {
        let url: URL
        let byteCount: Int
        let timestamp: Date
    }

    static func save(_ packet: WatchFilePacket) -> WatchMediaAttachment? {
        guard WatchIncomingMediaValidator.accepts(packet) else { return nil }
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = documents.appendingPathComponent("ReceivedMedia", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let safeName = safeFileName(packet.fileName)
        let url = uniqueURL(in: directory, preferredName: safeName)
        do {
            try packet.content.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return WatchMediaAttachment(
                url: url,
                fileName: url.lastPathComponent,
                mimeType: packet.mimeType ?? "application/octet-stream",
                byteCount: packet.content.count
            )
        } catch {
            return nil
        }
    }

    static func attachment(forLocalURL url: URL, mimeType: String) -> WatchMediaAttachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return WatchMediaAttachment(
            url: url,
            fileName: url.lastPathComponent,
            mimeType: mimeType,
            byteCount: size
        )
    }

    static func attachment(
        forStoredURL url: URL,
        fallbackMimeType: String?
    ) -> WatchMediaAttachment {
        let mimeType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png": mimeType = "image/png"
        case "gif": mimeType = "image/gif"
        case "webp": mimeType = "image/webp"
        case "m4a": mimeType = "audio/mp4"
        case "aac": mimeType = "audio/aac"
        case "mp3": mimeType = "audio/mpeg"
        case "wav": mimeType = "audio/wav"
        case "ogg": mimeType = "audio/ogg"
        case "pdf": mimeType = "application/pdf"
        default: mimeType = fallbackMimeType ?? "application/octet-stream"
        }
        return attachment(forLocalURL: url, mimeType: mimeType)
    }

    static func remove(_ attachment: WatchMediaAttachment) {
        try? FileManager.default.removeItem(at: attachment.url)
    }

    static func compactWaveform(for url: URL, bars: Int = 32) -> [Float] {
        guard bars > 0,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let capacity = AVAudioFrameCount(exactly: file.length),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: capacity
              ) else {
            return Array(repeating: 0.3, count: max(1, bars))
        }
        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.3, count: bars)
        }
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return Array(repeating: 0.3, count: bars)
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let strideSize = max(1, frameCount / bars)
        return (0..<bars).map { index in
            let start = min(frameCount, index * strideSize)
            let end = index == bars - 1
                ? frameCount
                : min(frameCount, start + strideSize)
            guard start < end else { return 0.08 }
            var sum: Float = 0
            for frame in start..<end {
                for channel in 0..<channelCount {
                    sum += abs(channels[channel][frame])
                }
            }
            let mean = sum / Float((end - start) * max(1, channelCount))
            return max(0.08, min(1, mean * 2.4))
        }
    }

    /// Bounds watch storage while retaining every attachment still referenced
    /// by the persisted conversation. Unreferenced oldest files are removed
    /// first across received media and locally recorded voice notes.
    @discardableResult
    static func prune(protectedURLs: Set<URL>) -> Int {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return 0 }
        let protectedPaths = Set(protectedURLs.map {
            $0.standardizedFileURL.path
        })
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let directories = ["ReceivedMedia", "VoiceNotes"].map {
            documents.appendingPathComponent($0, isDirectory: true)
        }
        var files: [(url: URL, size: Int, date: Date)] = []
        for directory in directories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                files.append((
                    url.standardizedFileURL,
                    max(0, values.fileSize ?? 0),
                    values.contentModificationDate ?? .distantPast
                ))
            }
        }
        var totalBytes = files.reduce(0) { $0 + $1.size }
        var totalFiles = files.count
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard totalBytes > maximumStoredBytes
                    || totalFiles > maximumStoredFiles else { break }
            guard !protectedPaths.contains(file.url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalBytes -= file.size
                totalFiles -= 1
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    /// Selects the oldest conversation attachments that must be detached so
    /// active references cannot defeat the byte/file retention ceilings.
    static func retentionVictimURLs(
        from candidates: [RetentionCandidate]
    ) -> Set<URL> {
        var unique: [String: RetentionCandidate] = [:]
        for candidate in candidates {
            let normalized = candidate.url.standardizedFileURL
            let path = normalized.path
            let normalizedCandidate = RetentionCandidate(
                url: normalized,
                byteCount: max(0, candidate.byteCount),
                timestamp: candidate.timestamp
            )
            if let existing = unique[path] {
                unique[path] = RetentionCandidate(
                    url: normalized,
                    byteCount: max(existing.byteCount, normalizedCandidate.byteCount),
                    timestamp: max(existing.timestamp, normalizedCandidate.timestamp)
                )
            } else {
                unique[path] = normalizedCandidate
            }
        }

        var totalBytes = unique.values.reduce(0) { $0 + $1.byteCount }
        var totalFiles = unique.count
        var victims = Set<URL>()
        for candidate in unique.values.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard totalBytes > maximumStoredBytes
                    || totalFiles > maximumStoredFiles else { break }
            victims.insert(candidate.url)
            totalBytes -= candidate.byteCount
            totalFiles -= 1
        }
        return victims
    }

    private static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let initial = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let stem = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        let suffix = String(UUID().uuidString.prefix(8))
        return directory.appendingPathComponent(
            ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
        )
    }

    private static func safeFileName(_ proposedName: String?) -> String {
        let leaf = ((proposedName ?? "") as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUnsafePathMeaning = leaf.isEmpty || leaf == "." || leaf == ".."
        let sanitized = leaf.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? "_" : Character(String(scalar))
        }
        let bounded = String(String(sanitized).prefix(120))
        return hasUnsafePathMeaning || bounded.isEmpty
            ? "file-\(UUID().uuidString)"
            : bounded
    }
}

private enum WatchIncomingMediaValidator {
    static func accepts(_ packet: WatchFilePacket) -> Bool {
        guard packet.fileSize == UInt64(packet.content.count),
              let mime = packet.mimeType?.lowercased() else { return false }
        let data = packet.content
        switch mime {
        case "application/octet-stream":
            return true
        case "application/pdf":
            return data.starts(with: [0x25, 0x50, 0x44, 0x46])
        case "image/jpeg", "image/jpg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/gif":
            return data.count >= 6
                && data.starts(with: [0x47, 0x49, 0x46, 0x38])
                && (data[4] == 0x37 || data[4] == 0x39)
                && data[5] == 0x61
        case "image/webp":
            return data.count >= 12
                && data.starts(with: [0x52, 0x49, 0x46, 0x46])
                && Data(data[8..<12]) == Data([0x57, 0x45, 0x42, 0x50])
        case "audio/mp4", "audio/m4a":
            return hasISOBaseMediaHeader(data)
        case "audio/aac":
            return hasISOBaseMediaHeader(data)
                || (data.count >= 2 && data[0] == 0xFF && (data[1] & 0xF6) == 0xF0)
        case "audio/mpeg", "audio/mp3":
            return data.starts(with: [0x49, 0x44, 0x33])
                || (data.count >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0)
        case "audio/wav", "audio/x-wav":
            return data.count >= 12
                && data.starts(with: [0x52, 0x49, 0x46, 0x46])
                && Data(data[8..<12]) == Data([0x57, 0x41, 0x56, 0x45])
        case "audio/ogg":
            return data.starts(with: [0x4F, 0x67, 0x67, 0x53])
        default:
            return false
        }
    }

    private static func hasISOBaseMediaHeader(_ data: Data) -> Bool {
        data.count >= 12
            && Data(data[4..<8]) == Data([0x66, 0x74, 0x79, 0x70])
    }
}

@MainActor
final class WatchVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var samples = Array(repeating: Float(0.08), count: 32)
    @Published private(set) var cancelArmed = false

    var onFinish: ((URL) -> Void)?

    /// Evaluated at the start of each hold. DMs return nil until their Noise
    /// session is established, preserving classic record-then-send fallback.
    var liveFrameSenderProvider: (() -> ((Data) -> Void)?)?

    private var recorder: AVAudioRecorder?
    private var ownsClassicAudioSession = false
    private var liveCapture: WatchPTTCaptureEngine?
    private var timer: Timer?
    private var outputURL: URL?
    private var liveStream: LiveStreamState?
    private var startedAt = Date()
    private var isRequestingPermission = false
    private var startRequested = false
    private var pendingStartTask: Task<Void, Never>?
    private let maximumDuration: TimeInterval = 10
    private let minimumDuration: TimeInterval = 0.6
    private static let startFeedbackSettleDelay: Duration = .milliseconds(300)

    /// Confined to the capture queue until `WatchPTTCaptureEngine.stop()`
    /// drains it. Main-queue delivery is enqueued in that same order.
    private final class LiveStreamState {
        let sender: (Data) -> Void
        var packetizer: VoiceBurstPacketizer
        var sentStart = false

        init(burstID: Data, sender: @escaping (Data) -> Void) {
            self.sender = sender
            packetizer = VoiceBurstPacketizer(burstID: burstID)
        }
    }

    func requestAndStart() {
        guard !isRecording, !startRequested else { return }
        startRequested = true

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            scheduleStartAfterFeedback()
        case .denied:
            startRequested = false
            WKInterfaceDevice.current().play(.failure)
        case .undetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRequestingPermission = false
                    if granted {
                        self.scheduleStartAfterFeedback()
                    } else {
                        self.startRequested = false
                        WKInterfaceDevice.current().play(.failure)
                    }
                }
            }
        @unknown default:
            startRequested = false
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func updateDrag(translation: CGSize) {
        let armed = translation.height < -44 || abs(translation.width) > 70
        if armed != cancelArmed {
            cancelArmed = armed
            WKInterfaceDevice.current().play(.click)
        }
    }

    func finishFromGesture() {
        let shouldSend = !cancelArmed
        cancelStartRequest()
        if isRecording {
            stop(send: shouldSend)
        } else {
            cancelArmed = false
        }
    }

    func cancel() {
        cancelStartRequest()
        if isRecording {
            stop(send: false)
        } else {
            cancelArmed = false
        }
    }

    private func scheduleStartAfterFeedback() {
        guard startRequested, pendingStartTask == nil else { return }
        WKInterfaceDevice.current().play(.start)
        pendingStartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.startFeedbackSettleDelay)
            } catch {
                return
            }
            guard let self, self.startRequested else { return }
            self.pendingStartTask = nil
            self.start()
        }
    }

    private func cancelStartRequest() {
        startRequested = false
        pendingStartTask?.cancel()
        pendingStartTask = nil
    }

    private func start() {
        guard !isRecording else { return }
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = documents.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let sender = liveFrameSenderProvider?() {
            let burstID = VoiceBurstPacket.makeBurstID()
            let url = directory.appendingPathComponent(
                "voice_\(burstID.hexEncodedString()).m4a"
            )
            if startLive(url: url, burstID: burstID, sender: sender) {
                recordingDidStart(url: url, live: true)
                return
            }
        }

        let url = directory.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        startClassic(url: url)
    }

    private func startClassic(url: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            try WatchLiveAudioSession.shared.acquireCapture()
            ownsClassicAudioSession = true
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                releaseClassicAudioSession()
                try? FileManager.default.removeItem(at: url)
                WKInterfaceDevice.current().play(.failure)
                return
            }
            self.recorder = recorder
            recordingDidStart(url: url, live: false)
        } catch {
            releaseClassicAudioSession()
            try? FileManager.default.removeItem(at: url)
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func startLive(
        url: URL,
        burstID: Data,
        sender: @escaping (Data) -> Void
    ) -> Bool {
        let capture = WatchPTTCaptureEngine()
        let stream = LiveStreamState(burstID: burstID, sender: sender)
        capture.onFrames = { frames in
            if !stream.sentStart {
                stream.sentStart = true
                if let packet = VoiceBurstPacket(
                    burstID: stream.packetizer.burstID,
                    seq: 0,
                    kind: .start(codec: .aacLC16kMono)
                ) {
                    Self.deliverOnMain(packet.encode(), with: stream.sender)
                }
            }
            for frame in frames {
                for packet in stream.packetizer.add(frame) {
                    Self.deliverOnMain(packet, with: stream.sender)
                }
            }
            // At 16 kbps a packet normally holds one AAC frame. Flushing per
            // tap callback avoids adding capture-buffer latency.
            for packet in stream.packetizer.flush() {
                Self.deliverOnMain(packet, with: stream.sender)
            }
        }
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.isRecording, self.isLive else { return }
                self.samples.removeFirst()
                self.samples.append(level)
            }
        }
        do {
            try capture.start(outputURL: url)
            liveCapture = capture
            liveStream = stream
            return true
        } catch {
            capture.cancel()
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    private func recordingDidStart(url: URL, live: Bool) {
        outputURL = url
        startedAt = Date()
        elapsed = 0
        samples = Array(repeating: 0.08, count: 32)
        cancelArmed = false
        isLive = live
        isRecording = true
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.08,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard isRecording else { return }
        if let recorder {
            recorder.updateMeters()
            let normalized = max(
                0.08,
                min(1, pow(10, recorder.averagePower(forChannel: 0) / 24))
            )
            samples.removeFirst()
            samples.append(normalized)
        }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= maximumDuration {
            stop(send: true)
        }
    }

    private func stop(send: Bool) {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        let duration = Date().timeIntervalSince(startedAt)
        let url = outputURL
        let wasLive = isLive
        let stream = liveStream
        let encodedFrames: Int

        if let liveCapture {
            if send {
                let result = liveCapture.stop()
                encodedFrames = result.encodedFrames
            } else {
                liveCapture.cancel()
                encodedFrames = 0
            }
        } else {
            recorder?.stop()
            encodedFrames = 0
            releaseClassicAudioSession()
        }

        recorder = nil
        liveCapture = nil
        liveStream = nil
        outputURL = nil
        isRecording = false
        isLive = false
        cancelArmed = false

        let capturedDuration = wasLive
            ? Double(encodedFrames) * PTTAudioFormat.frameDuration
            : duration
        let shouldSend = send
            && duration >= minimumDuration
            && capturedDuration >= minimumDuration
            && url != nil

        if wasLive, let stream {
            if shouldSend {
                for packet in stream.packetizer.flush() {
                    Self.deliverOnMain(packet, with: stream.sender)
                }
                let durationMs = UInt32(
                    min(Double(UInt32.max), (capturedDuration * 1_000).rounded())
                )
                if let packet = VoiceBurstPacket(
                    burstID: stream.packetizer.burstID,
                    seq: stream.packetizer.nextSeq,
                    kind: .end(
                        totalDataPackets: stream.packetizer.dataPacketCount,
                        durationMs: durationMs
                    )
                ) {
                    Self.deliverOnMain(packet.encode(), with: stream.sender)
                }
            } else if let packet = VoiceBurstPacket(
                burstID: stream.packetizer.burstID,
                seq: stream.packetizer.nextSeq,
                kind: .canceled
            ) {
                Self.deliverOnMain(packet.encode(), with: stream.sender)
            }
        }

        if shouldSend, let url {
            WKInterfaceDevice.current().play(.success)
            // Live frame callbacks enqueue onto main in capture order. Queue
            // final-file delivery after END so a receiver always sees the
            // control packet before its potentially fragmented `.m4a`.
            if wasLive {
                DispatchQueue.main.async { [weak self] in self?.onFinish?(url) }
            } else {
                onFinish?(url)
            }
        } else {
            if let url { try? FileManager.default.removeItem(at: url) }
            WKInterfaceDevice.current().play(send ? .failure : .retry)
        }
    }

    private func releaseClassicAudioSession() {
        guard ownsClassicAudioSession else { return }
        ownsClassicAudioSession = false
        WatchLiveAudioSession.shared.releaseCapture()
    }

    nonisolated private static func deliverOnMain(
        _ packet: Data,
        with sender: @escaping (Data) -> Void
    ) {
        DispatchQueue.main.async { sender(packet) }
    }
}

@MainActor
final class WatchAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private let url: URL
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL) {
        self.url = url
        super.init()
        if let player = try? AVAudioPlayer(contentsOf: url) {
            self.player = player
            duration = player.duration
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            timer?.invalidate()
            timer = nil
            isPlaying = false
        } else {
            guard player.play() else { return }
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.updateProgress() }
            }
        }
    }

    private func finishPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        progress = 0
        player?.currentTime = 0
    }

    private func updateProgress() {
        guard let player, player.duration > 0 else { return }
        if isPlaying, !player.isPlaying {
            finishPlayback()
            return
        }
        progress = player.currentTime / player.duration
    }
}
