//
// WatchConversationStore.swift
// bitchat
//
// A small, watch-local archive for the bounded public and direct-message
// timelines. The BLE controller remains the source of truth while running;
// this store only restores UI state after suspension, termination, or update.
//

import Foundation

struct WatchConversationSnapshot: Codable {
    var messages: [WatchChatMessage]
    var privateMessages: [String: [WatchChatMessage]]
    var unreadDms: [String: Int]

    static let empty = WatchConversationSnapshot(
        messages: [],
        privateMessages: [:],
        unreadDms: [:]
    )
}

final class WatchConversationStore {
    private let fileURL: URL
    private let queue = DispatchQueue(
        label: "chat.bitchat.watch.conversations",
        qos: .utility
    )

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("bitchat", isDirectory: true)
                .appendingPathComponent("watch-conversations-v1.json")
        }
    }

    func load() -> WatchConversationSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(
                WatchConversationSnapshot.self,
                from: data
              ) else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: WatchConversationSnapshot) {
        queue.async { [fileURL] in
            Self.write(snapshot, to: fileURL)
        }
    }

    /// Blocks only at lifecycle boundaries so the most recent state reaches
    /// disk before watchOS suspends the process.
    func flush(_ snapshot: WatchConversationSnapshot) {
        queue.sync { [fileURL] in
            Self.write(snapshot, to: fileURL)
        }
    }

    private static func write(_ snapshot: WatchConversationSnapshot, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(
                to: url,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
        } catch {
            // Persistence is best effort. The in-memory mesh must keep running
            // even if the watch is locked or temporarily out of storage.
        }
    }
}
