//
// BitchatWatchApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UserNotifications

@main
struct BitchatWatchApp: App {
    @StateObject private var ble: WatchBLEController

    init() {
        UNUserNotificationCenter.current().delegate = WatchNotificationDelegate.shared
        _ble = StateObject(wrappedValue: WatchBLEController())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble)
        }
        .backgroundTask(.bluetoothAlert) {
            await MainActor.run {
                ble.handleBluetoothBackgroundWake()
            }
        }
    }
}
