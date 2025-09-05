import Foundation
import Combine
import SwiftUI
import TorManager

@MainActor
final class TorService: ObservableObject {
    static let shared = TorService()

    // Whether the app should route traffic via Tor. Default: on.
    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "torEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "torEnabled") }
    }

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isConnecting: Bool = false
    // Simple progress for UI (0-100)
    @Published private(set) var progress: Int = 0

    private var cancellables = Set<AnyCancellable>()

    // Restart/stop coordination
    private var isStopping = false
    private var restartWorkItem: DispatchWorkItem?
    private var lastRestartAt: Date = .distantPast

    // Health probe coordination
    private var connectivityProbeInFlight = false
    private var lastConnectivityProbeAt: Date = .distantPast
    private let minProbeInterval: TimeInterval = 10
    private let probeTimeout: TimeInterval = 10

    private init() {
        // Ensure a shared TorManager instance is set up with a persistent directory
        _ = TorManager.shared // triggers lazy init extension below
        updateConnectionStatus()
    }

    // MARK: - Public API (adapter compatible with existing call sites)

    func startIfEnabled() {
        guard isEnabled else { return }
        if isConnecting || isConnected || isStopping { return }
        startTor()
    }

    func startTor() {
        guard isEnabled else { return }
        if isConnecting || isConnected || isStopping { return }
        isConnecting = true
        progress = 10

        // If a TORThread was left over somehow, stop first
        if TorManager.shared.torThread != nil && TorManager.shared.connected {
            TorManager.shared.stop()
        }

        TorManager.shared.start { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isConnecting = false
                if let error = error {
                    self.isConnected = false
                    self.progress = 0
                    SecureLogger.log("TorManager failed to start: \(error)", category: SecureLogger.session, level: .error)
                } else {
                    self.updateConnectionStatus()
                    self.progress = self.isConnected ? 100 : 50
                    if self.isConnected {
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }
        }
    }

    func stopTor() {
        restartWorkItem?.cancel()
        isStopping = true
        TorManager.shared.stop()
        isStopping = false
        isConnecting = false
        isConnected = false
        progress = 0
        // Reconnect Nostr websockets without Tor
        NostrRelayManager.shared.disconnect()
    }

    func restartTor() {
        guard isEnabled else { return }
        if Date().timeIntervalSince(lastRestartAt) < 3 { return }
        lastRestartAt = Date()
        restartWorkItem?.cancel()
        isStopping = true
        isConnecting = true
        isConnected = false
        progress = 20
        TorManager.shared.stop()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isStopping = false
            self.startTor()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func verifyTorOnResume() {
        guard isEnabled else { return }
        guard !isStopping else { return }
        if isConnected { return }
        guard !isConnecting else { return }
        probeTorConnectivity(timeout: probeTimeout) { [weak self] ok in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if ok {
                    self.updateConnectionStatus()
                    if self.isConnected && !NostrRelayManager.shared.isConnected {
                        NostrRelayManager.shared.resetAllConnections()
                    }
                } else {
                    self.restartTor()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }
        }
    }

    func scheduleActiveHealthCheck() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.verifyTorOnResume()
        }
    }

    /// Public helper used by NostrRelayManager when all relays are down.
    func checkTorConnectivityAndRecoverIfNeeded(trigger: String, completion: ((Bool) -> Void)? = nil) {
        let now = Date()
        if connectivityProbeInFlight { return }
        if now.timeIntervalSince(lastConnectivityProbeAt) < minProbeInterval { return }
        connectivityProbeInFlight = true
        lastConnectivityProbeAt = now
        probeTorConnectivity(timeout: probeTimeout) { [weak self] ok in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.connectivityProbeInFlight = false
                if ok {
                    completion?(true)
                } else {
                    self.restartTor()
                    completion?(false)
                }
            }
        }
    }

    /// Returns the URLSession to use for network/WebSocket traffic respecting Tor setting.
    func networkSession() -> URLSession {
        let config = URLSessionConfiguration.default
        if isEnabled {
            if let dict = TorManager.shared.torSocks5ProxyConf {
                config.connectionProxyDictionary = dict
            } else {
                // Fallback: assume default localhost:9050 until TorManager provides conf
                config.connectionProxyDictionary = [
                    kCFProxyTypeKey: kCFProxyTypeSOCKS,
                    kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
                    kCFStreamPropertySOCKSProxyHost: "127.0.0.1",
                    kCFStreamPropertySOCKSProxyPort: 9050
                ]
            }
        }
        return URLSession(configuration: config)
    }

    // MARK: - Internals

    private func updateConnectionStatus() {
        let connected = isEnabled && TorManager.shared.connected && TorManager.shared.torSocks5ProxyConf != nil
        isConnected = connected
        if connected { progress = 100 }
    }

    private func probeTorConnectivity(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
        guard isEnabled else { completion(false); return }
        let session = networkSession()
        guard let url = URL(string: "https://check.torproject.org/api/ip") else { completion(false); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = session.dataTask(with: request) { data, response, error in
            let ok = (error == nil) && (response as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
            completion(ok)
        }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
            if task.state == .running { task.cancel() }
        }
    }
}

extension URLSession {
    @MainActor static func torEnabledSession() -> URLSession {
        return TorService.shared.networkSession()
    }
}

// MARK: - TorManager bootstrap (shared instance with cache dir)
extension TorManager {
    /// Provide a single shared instance with a cache directory for Tor state.
    public static let shared: TorManager = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tor", isDirectory: true)
        return TorManager(directory: dir)
    }()
}
