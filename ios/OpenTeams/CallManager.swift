import AVFoundation
import CallKit
import UIKit

/// Presents Teams calls through CallKit, so they ring and show like phone
/// calls: the full-screen incoming call UI (also on the lock screen, following
/// the ring/silent switch and Focus), the call indicator in the status bar or
/// Dynamic Island, Recents, and correct interaction with cellular calls.
///
/// Teams stays in charge of the call itself; this class mirrors its state into
/// CallKit and turns CallKit actions into clicks on Teams' own buttons through
/// CallBridge:
/// - Incoming: Teams' ringing toast -> `reportNewIncomingCall`. Answer and
///   Decline in the iOS UI click Teams' accept/decline; if the toast goes away
///   on its own (caller hung up, answered elsewhere) the call ends.
/// - Connected calls (answered, placed or joined in Teams) without a CallKit
///   call get an outgoing CallKit call.
/// - End and Mute in the iOS UI click Teams' hang-up and microphone buttons;
///   muting in Teams is reflected back.
///
/// Audio, verified on a device:
/// - Teams' audio, including the microphone, runs in WebKit's GPU process,
///   which has its own audio session. The app's own session is never switched
///   to playAndRecord: doing so takes the microphone away from WebKit, and the
///   other side hears nothing. It stays in the keep-alive's mixable playback.
/// - Earlier lock-screen attempts hit WebKit audio activation errors
///   ("insufficient priority"). This candidate waits for didActivate before
///   accepting in Teams, retains the full CallKit call, and does not require
///   bringing the app forward. Locked-device two-way audio is NOT yet verified.
///
/// Holding is not supported: Teams web has no hold control to map it to.
final class CallManager: NSObject {
    private enum Phase {
        case ringing
        case answering
        case active
    }

    private struct Call {
        let uuid: UUID
        var phase: Phase
    }

    private let provider: CXProvider
    private let controller = CXCallController()
    private let bridge: CallBridge
    private let keepAlive: BackgroundKeepAlive
    private let notifications: NotificationBridge
    private var call: Call?
    /// Teams' mute state as last reported by the page.
    private var teamsMuted: Bool?
    /// Experimental: accept after CallKit activates audio, even while locked.
    private var answerPending = false
    private var audioActivated = false

    init(bridge: CallBridge, keepAlive: BackgroundKeepAlive, notifications: NotificationBridge) {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic, .phoneNumber]
        configuration.includesCallsInRecents = true
        configuration.iconTemplateImageData = UIImage(named: "CallKitIcon")?.pngData()
        provider = CXProvider(configuration: configuration)
        self.bridge = bridge
        self.keepAlive = keepAlive
        self.notifications = notifications
        super.init()
        provider.setDelegate(self, queue: nil)
        bridge.delegate = self
    }

    deinit {
        provider.invalidate()
    }

    private static func update(name: String, number: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        if number.isEmpty {
            update.remoteHandle = CXHandle(type: .generic, value: name.isEmpty ? "Microsoft Teams" : name)
        } else {
            update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        }
        update.localizedCallerName = name.isEmpty ? (number.isEmpty ? "Microsoft Teams" : nil) : name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    private static func log(_ message: String) {
        // Call state only; never caller names or numbers.
        print("[CALLKIT] \(message)")
    }

    // MARK: Answering

    private func acceptWhenAudioReady() {
        guard answerPending, audioActivated, let current = call,
              current.phase == .answering else { return }
        answerPending = false
        bridge.answer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, let call = self.call, call.uuid == current.uuid,
                  call.phase == .answering else { return }
            Self.log("Teams did not connect after answering")
            self.bridge.decline()
            self.provider.reportCall(with: call.uuid, endedAt: nil, reason: .failed)
            self.call = nil
            self.callFinished()
        }
    }

    // MARK: Teams -> CallKit

    /// Fallback when Teams' internal React lifecycle events are missing.
    /// MediaBridge reports real audio peer connections, including popup-free
    /// calls ending without render_disconected.
    func webRTCActivityChanged(_ active: Bool) {
        if active {
            connected()
        } else if call?.phase == .active {
            disconnected()
        }
    }

    private func reportIncoming(name: String, number: String) {
        if let call {
            // Teams refines a call-queue caller while ringing. A second call
            // while one is active is left to Teams' own toast.
            if call.phase == .ringing {
                provider.reportCall(with: call.uuid, updated: Self.update(name: name, number: number))
            }
            return
        }
        let uuid = UUID()
        call = Call(uuid: uuid, phase: .ringing)
        Self.log("incoming call ringing")
        notifications.holdNotificationsForRingingCall()
        provider.reportNewIncomingCall(with: uuid, update: Self.update(name: name, number: number)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let error else {
                    self.notifications.dropHeldNotifications()
                    return
                }
                Self.log("incoming call not reported: \(error.localizedDescription)")
                // Let Teams ring and notify on its own instead.
                self.notifications.releaseHeldNotifications()
                guard self.call?.uuid == uuid else { return }
                self.call = nil
                self.bridge.setRingtoneSuppressed(false)
            }
        }
    }

    private func incomingEnded() {
        guard let call else { return }
        // Accepting also dismisses the toast; wait for connection confirmation.
        if call.phase == .answering && !answerPending { return }
        guard call.phase != .active else { return }
        Self.log("incoming call ended before it was accepted in Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
        answerPending = false
    }

    private func connected() {
        keepAlive.callInProgress = true
        if var call {
            let answeredInTeams = call.phase == .ringing
            call.phase = .active
            self.call = call
            answerPending = false
            Self.log("call connected")
            if answeredInTeams {
                // Answered with Teams' own toast while CallKit was ringing:
                // tell CallKit, or the system UI keeps ringing. The answer
                // action is fulfilled without clicking Teams' accept again.
                Self.log("answered in Teams; reporting the answer to CallKit")
                controller.request(CXTransaction(action: CXAnswerCallAction(call: call.uuid))) { error in
                    if let error { Self.log("answer not reported to CallKit: \(error.localizedDescription)") }
                }
            }
            return
        }
        // Placed or joined from Teams, or answered and handed over to Teams.
        let uuid = UUID()
        call = Call(uuid: uuid, phase: .active)
        let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: "Microsoft Teams"))
        controller.request(CXTransaction(action: start)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                Self.log("call not shown in CallKit: \(error.localizedDescription)")
                guard let self, self.call?.uuid == uuid else { return }
                self.call = nil
                // Teams may still be in a real WebRTC call. MediaBridge owns
                // clearing the capture guard when those connections close.
            }
        }
    }

    private func disconnected() {
        guard let call else {
            callFinished()
            return
        }
        guard call.phase != .ringing else { return }
        Self.log("call ended in Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
        callFinished()
    }

    /// Remember Teams' state without initiating a second system mute
    /// transaction. Local capture track mute events are isolated in MediaBridge.
    private func mutedInTeams(_ isMuted: Bool) {
        teamsMuted = isMuted
        Self.log("Teams \(isMuted ? "muted" : "unmuted")")
    }

    private func callFinished() {
        teamsMuted = nil
        answerPending = false
        audioActivated = false
        keepAlive.callInProgress = false
        // CallKit may have interrupted the keep-alive.
        keepAlive.activateAudioSession()
        keepAlive.resume()
    }
}

// MARK: - CallBridgeDelegate

extension CallManager: CallBridgeDelegate {
    func callBridge(_ bridge: CallBridge, didReceive event: CallEvent) {
        switch event {
        case let .incoming(name, number):
            reportIncoming(name: name, number: number)
        case .incomingEnded:
            incomingEnded()
        case .connected:
            connected()
        case .disconnected:
            disconnected()
        case let .muted(isMuted):
            mutedInTeams(isMuted)
        }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let call {
            if call.phase == .ringing || answerPending { bridge.decline() }
            else { bridge.hangUp() }
        }
        call = nil
        callFinished()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard var call, call.uuid == action.callUUID else {
            action.fail()
            return
        }
        if call.phase == .active {
            // Already answered in Teams (see connected()).
            bridge.setRingtoneSuppressed(false)
            action.fulfill()
            return
        }
        call.phase = .answering
        self.call = call
        Self.log("answering")
        bridge.setRingtoneSuppressed(false)
        keepAlive.callInProgress = true
        answerPending = true
        action.fulfill()
        acceptWhenAudioReady()
        let uuid = call.uuid
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.call?.uuid == uuid, self.answerPending else { return }
            Self.log("CallKit audio did not activate for the answer")
            self.bridge.decline()
            self.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            self.call = nil
            self.callFinished()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call, call.uuid == action.callUUID {
            // Still ringing in Teams if the accept was waiting for the app.
            let ringingInTeams = call.phase == .ringing || answerPending
            Self.log(ringingInTeams ? "declining" : "hanging up")
            if ringingInTeams {
                bridge.decline()
            } else {
                bridge.hangUp()
            }
            bridge.setRingtoneSuppressed(false)
            self.call = nil
            callFinished()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        // Teams has already connected by the time this runs.
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        provider.reportCall(with: action.callUUID, updated: Self.update(name: "Microsoft Teams", number: ""))
        Self.log("Teams call shown in CallKit")
    }

    /// Apply the requested absolute state, not a toggle. MediaBridge prevents
    /// OS capture mute/unmute events from changing Teams' own button state.
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard call?.uuid == action.callUUID else { action.fail(); return }
        // An absolute request, never a toggle: a repeated mute cannot unmute.
        if teamsMuted != action.isMuted { bridge.setMuted(action.isMuted) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Self.log("audio activated; checking pending answer")
        audioActivated = true
        // WebKit owns capture; leave the host session's category alone.
        acceptWhenAudioReady()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActivated = false
        if call == nil {
            callFinished()
        }
    }
}
