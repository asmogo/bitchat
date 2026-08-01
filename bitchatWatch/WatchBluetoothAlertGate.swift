//
// WatchBluetoothAlertGate.swift
// bitchat
//
// Keeps a SwiftUI Bluetooth-alert task alive until the message carried by Core
// Bluetooth has been fully processed and handed to the notification center, or
// until a short timeout lets watchOS reclaim the process. The gate is deliberately
// transport-agnostic so its cancellation and race behaviour can be unit tested.
//

import Foundation

final class WatchBluetoothAlertGate: @unchecked Sendable {
    struct Ticket: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private enum State {
        case armed
        case waiting(CheckedContinuation<Void, Never>)
        case completed
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.count
    }

    /// Arms the gate synchronously before the handler's first suspension point.
    /// This closes the race where Core Bluetooth completes the alert while the
    /// background handler is still hopping to the main actor.
    func arm() -> Ticket {
        let ticket = Ticket(id: UUID())
        lock.lock()
        states[ticket.id] = .armed
        lock.unlock()
        return ticket
    }

    func wait(_ ticket: Ticket, timeoutNanoseconds: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    finish(ticket.id)
                    continuation.resume()
                    return
                }

                lock.lock()
                switch states[ticket.id] {
                case .armed:
                    states[ticket.id] = .waiting(continuation)
                    lock.unlock()

                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        self?.finish(ticket.id)
                    }
                case .completed:
                    states.removeValue(forKey: ticket.id)
                    lock.unlock()
                    continuation.resume()
                case .waiting, nil:
                    lock.unlock()
                    continuation.resume()
                }
            }
        } onCancel: {
            finish(ticket.id)
        }
    }

    /// Completes every outstanding alert task after the user-visible work that
    /// triggered the wake is complete.
    func signal() {
        lock.lock()
        var continuations: [CheckedContinuation<Void, Never>] = []
        let snapshot = states
        for (id, state) in snapshot {
            switch state {
            case .armed:
                states[id] = .completed
            case let .waiting(continuation):
                states.removeValue(forKey: id)
                continuations.append(continuation)
            case .completed:
                break
            }
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    private func finish(_ id: UUID) {
        lock.lock()
        let state = states.removeValue(forKey: id)
        lock.unlock()
        if case let .waiting(continuation) = state {
            continuation.resume()
        }
    }
}
