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
        controller.start()
        _ble = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble)
        }
        .backgroundTask(.bluetoothAlert) {
            await ble.handleBluetoothBackgroundWake()
        }
    }
}
