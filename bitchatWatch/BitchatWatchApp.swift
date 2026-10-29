//
// BitchatWatchApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UserNotifications
import WatchKit

@main
struct BitchatWatchApp: App {
    @StateObject private var ble: WatchBLEController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = WatchNotificationDelegate.shared
        // Core Bluetooth restoration only works if the central manager is
        // recreated during every process launch. A background Bluetooth
        // relaunch does not have to present ContentView, so starting from the
        // view's onAppear is too late (and sometimes never happens).
        let controller = WatchBLEController()
        let state = WKApplication.shared().applicationState
        controller.setApplicationState(
            isForeground: state != .background,
            isInteractive: state == .active
        )
        controller.resumeIfEnabled()
        _ble = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble)
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep lifecycle handling alive even when a background launch
            // never presents ContentView.
            ble.setApplicationState(
                isForeground: phase != .background,
                isInteractive: phase == .active
            )
        }
        .backgroundTask(.bluetoothAlert) {
            await ble.handleBluetoothBackgroundWake()
        }
        .backgroundTask(.appRefresh(WatchBackgroundRefreshSchedule.identifier)) { _ in
            await ble.handleBackgroundRefresh()
        }
    }
}
