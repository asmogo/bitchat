//
// WatchNotifications.swift
// bitchat
//

import Combine
import Foundation
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

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: promptCompletedKey)
                completion(granted)
            }
        }
    }

    static func markPromptSkipped() {
        UserDefaults.standard.set(true, forKey: promptCompletedKey)
    }

    static func notifyDirectMessage(
        peerID: String,
        sender: String,
        preview: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = preview
        content.sound = .default
        content.threadIdentifier = "dm-\(peerID)"
        content.userInfo = ["peerID": peerID]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
