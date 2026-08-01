//
// WatchNotifications.swift
// bitchat
//

import Combine
import Foundation
import os
import UserNotifications

final class WatchLaunchRouter: ObservableObject {
    static let shared = WatchLaunchRouter()
    @Published var requestedPeerID: String?
    private init() {}
}

final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let peerID = response.notification.request.content.userInfo["peerID"] as? String,
              !peerID.isEmpty else { return }
        await MainActor.run {
            WatchLaunchRouter.shared.requestedPeerID = peerID
        }
    }
}

enum WatchNotifications {
    static let promptCompletedKey = "notification_prompt_completed"
    private static let logger = Logger(
        subsystem: "chat.bitchat.watch",
        category: "notifications"
    )

    struct Descriptor: Equatable {
        let identifier: String
        let title: String
        let body: String
        let threadIdentifier: String
        let peerID: String?
    }

    static func shouldScheduleAlert(
        isAppInForeground: Bool,
        isConversationActive: Bool
    ) -> Bool {
        !isAppInForeground || !isConversationActive
    }

    static func directMessageDescriptor(
        messageID: String,
        peerID: String,
        sender: String,
        preview: String
    ) -> Descriptor {
        Descriptor(
            identifier: "dm-\(messageID)",
            title: sender,
            body: preview,
            threadIdentifier: "dm-\(peerID)",
            peerID: peerID
        )
    }

    static func publicMessageDescriptor(
        messageID: String,
        sender: String,
        preview: String
    ) -> Descriptor {
        Descriptor(
            identifier: "public-\(messageID)",
            title: "#mesh · \(sender)",
            body: preview,
            threadIdentifier: "public-mesh",
            peerID: nil
        )
    }

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                logger.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("authorization completed granted=\(granted)")
            }
            DispatchQueue.main.async {
                // A denied prompt is complete and must not be shown again.
                // A transient system error should remain retryable.
                if error == nil {
                    UserDefaults.standard.set(true, forKey: promptCompletedKey)
                }
                completion(granted)
            }
        }
    }

    static func markPromptSkipped() {
        UserDefaults.standard.set(true, forKey: promptCompletedKey)
    }

    static func notifyDirectMessage(
        messageID: String,
        peerID: String,
        sender: String,
        preview: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        schedule(
            directMessageDescriptor(
                messageID: messageID,
                peerID: peerID,
                sender: sender,
                preview: preview
            ),
            completion: completion
        )
    }

    static func notifyPublicMessage(
        messageID: String,
        sender: String,
        preview: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        schedule(
            publicMessageDescriptor(
                messageID: messageID,
                sender: sender,
                preview: preview
            ),
            completion: completion
        )
    }

    private static func schedule(
        _ descriptor: Descriptor,
        completion: ((Error?) -> Void)?
    ) {
        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        content.sound = .default
        content.threadIdentifier = descriptor.threadIdentifier
        if let peerID = descriptor.peerID {
            content.userInfo = ["peerID": peerID]
        }
        let request = UNNotificationRequest(
            identifier: descriptor.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error(
                    "scheduling \(descriptor.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                logger.debug("scheduled \(descriptor.identifier, privacy: .public)")
            }
            completion?(error)
        }
    }

    static func clearConversation(_ peerID: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { $0.request.content.threadIdentifier == "dm-\(peerID)" }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
