//
// ContentView.swift
// bitchat
//
// watchOS presentation parity with the Android Wear app.
//

import BitFoundation
import SwiftUI
import WatchKit

enum WatchPalette {
    static let green = Color(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let purple = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
    static let tertiary = Color(red: 0x6B / 255, green: 0x77 / 255, blue: 0x6B / 255)
    static let input = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    static let surface = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0B / 255)
    static let card = Color(red: 0x0D / 255, green: 0x18 / 255, blue: 0x0F / 255)

    static func peerColor(nickname: String, peerID: PeerID?) -> Color {
        let stableKey = nickname + (peerID?.id ?? "")
        var hash: UInt64 = 5381
        for byte in stableKey.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        var hue = Double(hash % 360) / 360
        let orangeHue = 30.0 / 360
        if abs(hue - orangeHue) < 0.05 {
            hue = (hue + 0.12).truncatingRemainder(dividingBy: 1)
        }
        return Color(hue: hue, saturation: 0.55, brightness: 0.82)
    }
}

private extension Font {
    static func bitchat(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private enum WatchRoute: Hashable {
    case people
    case directMessage(String)
    case profile(String)
    case verification(String)
    case compose(String?)
    case nickname
    case diagnostics
}

struct ContentView: View {
    @ObservedObject var ble: WatchBLEController
    @State private var nicknameReady =
        WatchDemoMode.isEnabled || WatchIdentity.shared.nicknameChosen
    @State private var notificationPromptCompleted =
        WatchDemoMode.isEnabled || UserDefaults.standard.bool(
            forKey: WatchNotifications.promptCompletedKey
        )
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !nicknameReady {
                NicknameSetupView(
                    initialNickname: ble.identity.nickname,
                    title: "bitchat",
                    subtitle: "Pick a nickname",
                    confirmLabel: "Join the mesh"
                ) { nickname in
                    ble.updateNickname(nickname)
                    nicknameReady = true
                }
            } else if !notificationPromptCompleted {
                NotificationSetupView {
                    notificationPromptCompleted = true
                }
            } else {
                WatchNavigation(ble: ble)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            ble.start()
            ble.setAppInForeground(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            ble.setAppInForeground(phase == .active)
        }
    }
}

private struct WatchNavigation: View {
    @ObservedObject var ble: WatchBLEController
    @ObservedObject private var launchRouter = WatchLaunchRouter.shared
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ConversationView(ble: ble, peerID: nil)
                .navigationDestination(for: WatchRoute.self) { route in
                    destination(route)
                }
        }
        .tint(WatchPalette.green)
        .onAppear { consumeLaunchRequest() }
        .onChange(of: launchRouter.requestedPeerID) { _, _ in
            consumeLaunchRequest()
        }
    }

    @ViewBuilder
    private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .people:
            PeopleView(ble: ble)
        case .directMessage(let id):
            ConversationView(ble: ble, peerID: PeerID(str: id))
        case .profile(let id):
            UserDetailView(ble: ble, peerID: PeerID(str: id))
        case .verification(let id):
            VerificationView(ble: ble, peerID: PeerID(str: id))
        case .compose(let id):
            TextComposerView { text in
                if let id {
                    ble.sendPrivateMessage(text, to: PeerID(str: id))
                } else {
                    ble.sendPublicMessage(text)
                }
            }
        case .nickname:
            NicknameSetupView(
                initialNickname: ble.identity.nickname,
                title: "You",
                subtitle: "How nearby peers see you",
                confirmLabel: "Save"
            ) { ble.updateNickname($0) }
        case .diagnostics:
            DiagnosticsView(ble: ble)
        }
    }

    private func consumeLaunchRequest() {
        guard let peerID = launchRouter.requestedPeerID else { return }
        path = [.directMessage(peerID)]
        launchRouter.requestedPeerID = nil
    }
}

// MARK: - Conversation

private struct ConversationView: View {
    @ObservedObject var ble: WatchBLEController
    let peerID: PeerID?
    @StateObject private var voice = WatchVoiceRecorder()
    @State private var imageAttachment: WatchMediaAttachment?

    private var thread: [WatchChatMessage] {
        if let peerID { return ble.privateMessages[peerID.id] ?? [] }
        return ble.messages
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if thread.isEmpty {
                            Text(emptyText)
                                .font(.bitchat(11, weight: .medium))
                                .foregroundStyle(WatchPalette.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                                .padding(.bottom, 28)
                        }
                        ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                WatchMessageRow(message: message) { attachment in
                                    imageAttachment = attachment
                                }
                                if index == thread.count - 1 {
                                    Color.clear.frame(height: 60)
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.top, 42)
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.automatic)
                .onChange(of: thread.count) { _, _ in
                    DispatchQueue.main.async {
                        if let last = thread.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        if let last = thread.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            ConversationHeader(ble: ble, peerID: peerID)
                .frame(maxHeight: .infinity, alignment: .top)

            ChatActionBar(
                peerID: peerID,
                recorder: voice,
                publicTalker: peerID == nil ? ble.activePublicVoiceTalker : nil
            )
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 11)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.9), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(maxHeight: .infinity, alignment: .bottom)

            if voice.isRecording {
                VoiceRecordingOverlay(recorder: voice)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .toolbar(peerID == nil ? .hidden : .visible, for: .navigationBar)
        .onAppear {
            voice.onFinish = { [weak ble] url in
                ble?.sendVoiceNote(url, to: peerID)
            }
            voice.liveFrameSenderProvider = { [weak ble] in
                ble?.liveVoiceFrameSender(to: peerID)
            }
            if let peerID {
                ble.openDirectMessage(peerID)
            } else {
                ble.openPublicConversation()
            }
        }
        .onDisappear {
            if let peerID {
                ble.closeDirectMessage(peerID)
            } else {
                ble.closePublicConversation()
            }
            if voice.isRecording { voice.cancel() }
        }
        .sheet(item: $imageAttachment) { attachment in
            FullScreenImageView(attachment: attachment)
        }
    }

    private var emptyText: String {
        if ble.centralState == "unauthorized" {
            return "Bluetooth access is required\nEnable it in Settings"
        }
        if ble.centralState == "poweredOff" {
            return "Turn on Bluetooth\nto join the mesh"
        }
        if ble.centralState == "unsupported" {
            return "Bluetooth mesh is unavailable\non this device"
        }
        if ble.centralState == "identityUnavailable" {
            return "Secure identity unavailable\nRestart after unlocking your watch"
        }
        if let peerID {
            return ble.hasEstablishedSession(peerID)
                ? "Encrypted channel ready\nSay hi"
                : "Setting up encryption…"
        }
        return "No messages yet\nSay hi to the mesh"
    }
}

extension WatchMediaAttachment: Identifiable {
    var id: String { url.path }
}

private struct ConversationHeader: View {
    @ObservedObject var ble: WatchBLEController
    let peerID: PeerID?

    var body: some View {
        Group {
            if let peerID {
                NavigationLink(value: WatchRoute.profile(peerID.id)) {
                    directMessageHeader(peerID)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: WatchRoute.people) {
                    publicHeader
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            LinearGradient(
                colors: [.black, .black.opacity(0.82), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var publicHeader: some View {
        let unread = ble.unreadDms.values.reduce(0, +)
        return HStack(spacing: 4) {
            if unread == 0 {
                Text("bitchat")
                    .font(.bitchat(15, weight: .bold))
                    .foregroundStyle(WatchPalette.green)
                    .padding(.trailing, 4)
            }
            Image(systemName: "person.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WatchPalette.green)
            Text("\(ble.peers.count)")
                .font(.bitchat(12, weight: .medium))
                .foregroundStyle(WatchPalette.green)
            if unread > 0 {
                Image(systemName: "envelope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WatchPalette.orange)
                    .padding(.leading, 3)
                Text("\(unread)")
                    .font(.bitchat(12, weight: .medium))
                    .foregroundStyle(WatchPalette.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func directMessageHeader(_ peerID: PeerID) -> some View {
        let peer = ble.peer(peerID)
        let nickname = peer?.nickname ?? String(peerID.id.prefix(8))
        let trust = ble.trust(for: peerID)
        return HStack(spacing: 4) {
            Text(nickname)
                .font(.bitchat(15, weight: .bold))
                .foregroundStyle(WatchPalette.peerColor(nickname: nickname, peerID: peerID))
                .lineLimit(1)
            NoiseLockIcon(established: ble.hasEstablishedSession(peerID))
            if trust.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(WatchPalette.orange)
            }
            if trust.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(WatchPalette.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct NoiseLockIcon: View {
    let established: Bool

    var body: some View {
        Image(systemName: established ? "lock.fill" : "lock.rotation")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(established ? WatchPalette.green : WatchPalette.tertiary)
            .symbolEffect(.pulse, isActive: !established)
    }
}

private struct WatchMessageRow: View {
    let message: WatchChatMessage
    let onOpenImage: (WatchMediaAttachment) -> Void

    private var senderColor: Color {
        message.isSelf
            ? WatchPalette.orange
            : WatchPalette.peerColor(
                nickname: message.sender,
                peerID: message.senderPeerID
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(message.isSelf ? "you" : message.sender)
                    .font(.bitchat(13, weight: .semibold))
                    .foregroundStyle(senderColor)
                    .lineLimit(1)
                Text(Self.timeFormatter.string(from: message.timestamp))
                    .font(.bitchat(9, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)
                if !message.status.isEmpty {
                    Text(message.status)
                        .font(.bitchat(8, weight: .medium))
                        .foregroundStyle(
                            message.status == "failed"
                                ? Color.red
                                : WatchPalette.tertiary
                        )
                        .lineLimit(1)
                }
            }

            if let attachment = message.media {
                MediaMessageView(attachment: attachment, onOpenImage: onOpenImage)
            } else {
                Text(message.content)
                    .font(.bitchat(13))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        ))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ChatActionBar: View {
    let peerID: PeerID?
    @ObservedObject var recorder: WatchVoiceRecorder
    let publicTalker: String?

    var body: some View {
        HStack(spacing: 2) {
            NavigationLink(value: WatchRoute.compose(peerID?.id)) {
                actionCircle(systemName: "keyboard.fill")
                    .frame(width: 54, height: 54)
                    .contentShape(Circle())
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .buttonStyle(.plain)
            .accessibilityLabel("Type message")

            actionCircle(
                systemName: recorder.cancelArmed ? "xmark" : "mic.fill",
                foreground: recorder.isRecording ? .black : WatchPalette.green,
                background: recorder.cancelArmed
                    ? .red
                    : (recorder.isRecording ? WatchPalette.green : WatchPalette.input)
            )
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !recorder.isRecording {
                            recorder.requestAndStart()
                        }
                        recorder.updateDrag(translation: value.translation)
                    }
                    .onEnded { _ in
                        recorder.finishFromGesture()
                    }
            )
            .accessibilityLabel("Push to talk")
        }
        .overlay(alignment: .top) {
            if let publicTalker, !recorder.isRecording {
                Text("LIVE · \(publicTalker)")
                    .font(.bitchat(8, weight: .bold))
                    .foregroundStyle(WatchPalette.green)
                    .lineLimit(1)
                    .offset(y: -7)
            }
        }
    }

    private func actionCircle(
        systemName: String,
        foreground: Color = WatchPalette.green,
        background: Color = WatchPalette.input
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 42, height: 42)
            .background(background, in: Circle())
    }
}

private struct VoiceRecordingOverlay: View {
    @ObservedObject var recorder: WatchVoiceRecorder

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: recorder.cancelArmed ? "xmark" : "mic.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 54, height: 54)
                .background(
                    recorder.cancelArmed ? Color.red : WatchPalette.green,
                    in: Circle()
                )
                .scaleEffect(recorder.cancelArmed ? 1.2 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: recorder.cancelArmed)

            WaveformView(
                samples: recorder.samples,
                progress: 1,
                active: recorder.cancelArmed ? .red : WatchPalette.green
            )
            .frame(height: 42)
            .padding(.horizontal, 18)

            Text("\(formatDuration(recorder.elapsed)) / 0:10")
                .font(.bitchat(13, weight: .semibold))
                .foregroundStyle(.white)
            Text(
                recorder.cancelArmed
                    ? "Release to cancel"
                    : (recorder.isLive ? "LIVE · lift to save" : "Lift finger to send")
            )
                .font(.bitchat(11, weight: .medium))
                .foregroundStyle(recorder.cancelArmed ? Color.red : WatchPalette.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.97).ignoresSafeArea())
    }
}

// MARK: - People and profile

private struct PeopleView: View {
    @ObservedObject var ble: WatchBLEController

    private var sortedPeers: [WatchPeer] {
        ble.peers.sorted {
            let leftUnread = ble.unreadDms[$0.id, default: 0] > 0
            let rightUnread = ble.unreadDms[$1.id, default: 0] > 0
            if leftUnread != rightUnread { return leftUnread }
            return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                Text("People (\(ble.peers.count))")
                    .font(.bitchat(16, weight: .bold))
                    .foregroundStyle(WatchPalette.green)
                    .padding(.bottom, 2)

                NavigationLink(value: WatchRoute.nickname) {
                    PersonCard {
                        HStack(spacing: 2) {
                            Text(ble.identity.nickname)
                                .font(.bitchat(13, weight: .semibold))
                                .foregroundStyle(WatchPalette.orange)
                            Text("(you)")
                                .font(.bitchat(11, weight: .medium))
                                .foregroundStyle(WatchPalette.tertiary)
                        }
                        Text("Tap to rename")
                            .font(.bitchat(11, weight: .medium))
                            .foregroundStyle(WatchPalette.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if sortedPeers.isEmpty {
                    Text("No one nearby yet\nKeep the app open to mesh")
                        .font(.bitchat(11, weight: .medium))
                        .foregroundStyle(WatchPalette.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                }

                ForEach(sortedPeers) { peer in
                    NavigationLink(value: WatchRoute.directMessage(peer.id)) {
                        PeerCard(
                            peer: peer,
                            encrypted: ble.hasEstablishedSession(peer.peerID),
                            trust: ble.trust(for: peer.peerID),
                            unreadCount: ble.unreadDms[peer.id, default: 0]
                        )
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink(value: WatchRoute.diagnostics) {
                    Label("Mesh diagnostics", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.bitchat(10, weight: .medium))
                        .foregroundStyle(WatchPalette.tertiary)
                        .padding(.top, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black)
    }
}

private struct PersonCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(WatchPalette.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct PeerCard: View {
    let peer: WatchPeer
    let encrypted: Bool
    let trust: WatchPeerTrust
    let unreadCount: Int

    var body: some View {
        PersonCard {
            HStack(spacing: 4) {
                Text(peer.nickname)
                    .font(.bitchat(13, weight: .semibold))
                    .foregroundStyle(
                        WatchPalette.peerColor(
                            nickname: peer.nickname,
                            peerID: peer.peerID
                        )
                    )
                    .lineLimit(1)
                if encrypted { NoiseLockIcon(established: true) }
                if trust.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WatchPalette.orange)
                }
                if trust.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WatchPalette.green)
                }
                Spacer(minLength: 2)
                if unreadCount > 0 {
                    Image(systemName: "envelope")
                        .font(.system(size: 11))
                        .foregroundStyle(WatchPalette.orange)
                    Text("\(unreadCount)")
                        .font(.bitchat(10, weight: .medium))
                        .foregroundStyle(WatchPalette.orange)
                }
            }
            Text(encrypted ? "Encrypted channel ready" : "Tap to chat")
                .font(.bitchat(11, weight: .medium))
                .foregroundStyle(WatchPalette.tertiary)
        }
    }
}

private struct UserDetailView: View {
    @ObservedObject var ble: WatchBLEController
    let peerID: PeerID

    var body: some View {
        let peer = ble.peer(peerID)
        let nickname = peer?.nickname ?? String(peerID.id.prefix(8))
        let trust = ble.trust(for: peerID)

        ScrollView {
            VStack(spacing: 8) {
                Text(nickname)
                    .font(.bitchat(15, weight: .bold))
                    .foregroundStyle(
                        WatchPalette.peerColor(nickname: nickname, peerID: peerID)
                    )
                    .lineLimit(1)
                Text("User details")
                    .font(.bitchat(10, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)

                Button {
                    ble.toggleFavorite(peerID)
                } label: {
                    DetailCard(
                        icon: trust.isFavorite ? "star.fill" : "star",
                        iconColor: trust.isFavorite || trust.theyFavoritedUs
                            ? WatchPalette.orange
                            : WatchPalette.tertiary,
                        title: favoriteTitle(trust),
                        subtitle: favoriteSubtitle(trust)
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: WatchRoute.verification(peerID.id)) {
                    DetailCard(
                        icon: trust.isVerified ? "checkmark.seal.fill" : "lock.fill",
                        iconColor: trust.isVerified
                            ? WatchPalette.green
                            : WatchPalette.tertiary,
                        title: trust.isVerified ? "Identity verified" : "Verification code",
                        subtitle: "Compare cryptographic fingerprints"
                    )
                }
                .buttonStyle(.plain)

                Text("Peer \(peerID.id.prefix(8))")
                    .font(.bitchat(10, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black)
    }

    private func favoriteTitle(_ trust: WatchPeerTrust) -> String {
        if trust.isFavorite && trust.theyFavoritedUs { return "Mutual favorite" }
        if trust.isFavorite { return "Favorited" }
        if trust.theyFavoritedUs { return "Favorite back" }
        return "Add favorite"
    }

    private func favoriteSubtitle(_ trust: WatchPeerTrust) -> String {
        if trust.isFavorite && trust.theyFavoritedUs { return "You favorited each other" }
        if trust.isFavorite { return "Remove from favorites" }
        if trust.theyFavoritedUs { return "They favorited you" }
        return "Keep this person easy to find"
    }
}

private struct DetailCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.bitchat(12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.bitchat(9, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(WatchPalette.input, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct VerificationView: View {
    @ObservedObject var ble: WatchBLEController
    let peerID: PeerID

    var body: some View {
        let trust = ble.trust(for: peerID)
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: trust.isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(trust.isVerified ? WatchPalette.green : WatchPalette.orange)
                Text(trust.isVerified ? "Verified" : "Verify identity")
                    .font(.bitchat(14, weight: .bold))
                    .foregroundStyle(WatchPalette.green)

                FingerprintCard(
                    title: "Their code",
                    fingerprint: ble.fingerprint(for: peerID)
                )
                FingerprintCard(
                    title: "Your code",
                    fingerprint: ble.identity.fingerprint
                )
                Text("Compare both full codes in person or over a trusted channel.")
                    .font(.bitchat(9, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)
                    .multilineTextAlignment(.center)

                Button(trust.isVerified ? "Remove verification" : "Mark verified") {
                    ble.setVerified(!trust.isVerified, peerID: peerID)
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchPalette.green)
                .disabled(ble.fingerprint(for: peerID) == nil)
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black)
    }
}

private struct FingerprintCard: View {
    let title: String
    let fingerprint: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.bitchat(10, weight: .bold))
                .foregroundStyle(WatchPalette.tertiary)
            Text(fingerprint.map(formatFingerprint) ?? "Handshake pending")
                .font(.bitchat(9, weight: .medium))
                .foregroundStyle(fingerprint == nil ? WatchPalette.orange : .white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(WatchPalette.input, in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatFingerprint(_ fingerprint: String) -> String {
        let groups = stride(from: 0, to: fingerprint.count, by: 4).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: min(4, fingerprint.count - offset))
            return String(fingerprint[start..<end]).uppercased()
        }
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
            .joined(separator: "\n")
    }
}

// MARK: - Input and onboarding

private struct TextComposerView: View {
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            TextField("Message", text: $text)
                .font(.bitchat(13))
                .textFieldStyle(.plain)
                .focused($focused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(WatchPalette.input, in: RoundedRectangle(cornerRadius: 18))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(WatchPalette.green, in: Circle())
                    .frame(width: 54, height: 54)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 14)
        .background(Color.black)
        .task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                focused = true
            } catch {
                // The view disappeared before the focus request fired.
            }
        }
    }

    private func send() {
        send(text)
    }

    private func send(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        WKInterfaceDevice.current().play(.click)
        dismiss()
    }
}

private struct NicknameSetupView: View {
    let initialNickname: String
    let title: String
    let subtitle: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    @State private var nickname: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        initialNickname: String,
        title: String,
        subtitle: String,
        confirmLabel: String,
        onConfirm: @escaping (String) -> Void
    ) {
        self.initialNickname = initialNickname
        self.title = title
        self.subtitle = subtitle
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        _nickname = State(initialValue: initialNickname)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.bitchat(16, weight: .bold))
                .foregroundStyle(WatchPalette.green)
            Text(subtitle)
                .font(.bitchat(11, weight: .medium))
                .foregroundStyle(WatchPalette.tertiary)
                .multilineTextAlignment(.center)
            TextField("Nickname", text: $nickname)
                .font(.bitchat(13))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onChange(of: nickname) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 24 { nickname = String(trimmed.prefix(24)) }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 46)
                .background(WatchPalette.input, in: RoundedRectangle(cornerRadius: 18))
            Button(confirmLabel) {
                let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onConfirm(trimmed)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchPalette.green)
            .foregroundStyle(.black)
            .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .background(Color.black.ignoresSafeArea())
        .onAppear { focused = true }
    }
}

private struct NotificationSetupView: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Text("Message alerts")
                .font(.bitchat(15, weight: .bold))
                .foregroundStyle(WatchPalette.green)
            Text("Alerts for encrypted direct messages")
                .font(.bitchat(11, weight: .medium))
                .foregroundStyle(WatchPalette.tertiary)
                .multilineTextAlignment(.center)
            Button("Enable") {
                WatchNotifications.requestAuthorization { _ in onComplete() }
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchPalette.green)
            Button("Not now") {
                WatchNotifications.markPromptSkipped()
                onComplete()
            }
            .font(.bitchat(11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(WatchPalette.tertiary)
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Media

private struct MediaMessageView: View {
    let attachment: WatchMediaAttachment
    let onOpenImage: (WatchMediaAttachment) -> Void

    @ViewBuilder
    var body: some View {
        switch attachment.kind {
        case .image:
            WatchImageThumbnail(attachment: attachment) {
                onOpenImage(attachment)
            }
        case .audio:
            VoiceNoteView(attachment: attachment)
                .id(attachment.url)
        case .file:
            FileChip(attachment: attachment)
        }
    }
}

private struct WatchImageThumbnail: View {
    let attachment: WatchMediaAttachment
    let onOpen: () -> Void

    var body: some View {
        if let image = UIImage(contentsOfFile: attachment.url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture(perform: onOpen)
        } else {
            FileChip(attachment: attachment)
        }
    }
}

private struct FullScreenImageView: View {
    let attachment: WatchMediaAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image = UIImage(contentsOfFile: attachment.url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white.opacity(0.75))
                .onTapGesture { dismiss() }
                .padding(.top, 5)
        }
    }
}

private struct VoiceNoteView: View {
    let attachment: WatchMediaAttachment
    @StateObject private var player: WatchAudioPlayer
    private let samples: [Float]

    init(attachment: WatchMediaAttachment) {
        self.attachment = attachment
        _player = StateObject(wrappedValue: WatchAudioPlayer(url: attachment.url))
        samples = WatchMediaStore.compactWaveform(for: attachment.url)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: player.toggle) {
                Image(
                    systemName: attachment.isLive
                        ? "waveform"
                        : (player.isPlaying ? "pause.fill" : "play.fill")
                )
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(WatchPalette.green, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(attachment.isLive)

            WaveformView(
                samples: samples,
                progress: player.progress,
                active: WatchPalette.green
            )
            .frame(minWidth: 32, maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            .clipped()

            Text(
                attachment.isLive
                    ? "LIVE"
                    : formatDuration(
                        player.isPlaying ? player.duration * player.progress : player.duration
                    )
            )
                .font(.bitchat(9, weight: .medium))
                .foregroundStyle(attachment.isLive ? WatchPalette.green : WatchPalette.tertiary)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(WatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let active: Color

    var body: some View {
        GeometryReader { geometry in
            let maximumBars = max(1, Int(geometry.size.width / 3))
            let visibleSamples = downsampled(to: maximumBars)
            let count = max(1, visibleSamples.count)
            let gap: CGFloat = 1.5
            let width = max(1, (geometry.size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(
                            Double(index) / Double(count) <= progress
                                ? active
                                : WatchPalette.tertiary.opacity(0.5)
                        )
                        .frame(
                            width: width,
                            height: max(2, geometry.size.height * CGFloat(visibleSamples[index]))
                        )
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func downsampled(to maximumBars: Int) -> [Float] {
        guard samples.count > maximumBars, maximumBars > 0 else { return samples }
        return (0..<maximumBars).map { index in
            let start = index * samples.count / maximumBars
            let end = max(start + 1, (index + 1) * samples.count / maximumBars)
            return samples[start..<min(end, samples.count)].max() ?? 0.08
        }
    }
}

private struct FileChip: View {
    let attachment: WatchMediaAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(attachment.fileName)
                .font(.bitchat(10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(formatBytes(attachment.byteCount))
                .font(.bitchat(9, weight: .medium))
                .foregroundStyle(WatchPalette.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(WatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration))
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func formatBytes(_ bytes: Int) -> String {
    if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    if bytes >= 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
    return "\(bytes) B"
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @ObservedObject var ble: WatchBLEController

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(ble.running ? WatchPalette.green : .red)
                Text("Diagnostics")
                    .font(.bitchat(13, weight: .bold))
                Spacer()
                Text(ble.centralState)
                    .font(.bitchat(8, weight: .medium))
                    .foregroundStyle(WatchPalette.tertiary)
            }
            Text("links \(ble.linkCount) · rx \(ble.rxBytes) · tx \(ble.txBytes)")
                .font(.bitchat(8, weight: .medium))
                .foregroundStyle(WatchPalette.tertiary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ble.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.bitchat(7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: ble.logLines.count) { _, _ in
                    if let last = ble.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Button(ble.running ? "Stop" : "Start") {
                    ble.running ? ble.stop() : ble.start()
                }
                Button("Clear") { ble.clearLog() }
            }
            .font(.bitchat(9, weight: .medium))
        }
        .background(Color.black)
    }
}

#Preview {
    ContentView(ble: WatchBLEController())
}
