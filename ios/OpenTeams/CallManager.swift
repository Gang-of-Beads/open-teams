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
/// - While a CallKit call is active, WebKit's session cannot activate from an
///   inactive state ("insufficient priority"), so the microphone cannot start.
///   It is fine when WebKit's audio is already active, as when answering with
///   the app in the foreground. When answering on the lock screen or in the
///   background, the CallKit call is kept until the user brings the app
///   forward, then ended, and only after CallKit has released its audio is the
///   call accepted in Teams. Once Teams connects, a new CallKit call shows it.
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
    /// The CallKit call's mute state.
    private var muted = false
    /// Teams' mute state as last reported by the page.
    private var teamsMuted: Bool?
    /// Answered in CallKit while the app was not in the foreground; Teams'
    /// accept waits until the app is active (see `answer`).
    private var acceptWhenActive = false
    /// The CallKit call was ended to hand over to Teams; accept once CallKit
    /// has released its audio.
    private var acceptAfterCallKitAudio = false
    private var activeObserver: NSObjectProtocol?

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
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handOverIfPending() }
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
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

    /// Accept in Teams right away when the app is active: WebKit's audio is
    /// running and the page is visible, so the microphone starts. Otherwise
    /// wait for the user to bring the app forward.
    private func answer() {
        if UIApplication.shared.applicationState == .active {
            bridge.answer()
        } else {
            acceptWhenActive = true
            Self.log("answered while in the background; accepting when the app is active")
        }
    }

    /// The app became active with an answer pending: end the CallKit call so
    /// WebKit can activate its audio, then accept once CallKit's audio is
    /// released. `connected` shows the Teams call in CallKit again.
    private func handOverIfPending() {
        guard acceptWhenActive, let call, call.phase == .answering else { return }
        acceptWhenActive = false
        acceptAfterCallKitAudio = true
        Self.log("app active; handing the call over to Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .answeredElsewhere)
        self.call = nil
        // CallKit normally reports didDeactivate right away; do not wait for
        // it forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.acceptAfterHandOver()
        }
    }

    private func acceptAfterHandOver() {
        guard acceptAfterCallKitAudio else { return }
        acceptAfterCallKitAudio = false
        // Let the page settle into the foreground before Teams asks for the
        // microphone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Self.log("accepting in Teams")
            self?.bridge.answer()
        }
    }

    // MARK: Teams -> CallKit

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
        guard let call else {
            // The caller gave up while we were handing over to Teams.
            acceptAfterCallKitAudio = false
            return
        }
        // While answering, the toast disappears because we clicked accept,
        // unless the accept is still waiting for the app to become active.
        if call.phase == .answering && !acceptWhenActive { return }
        guard call.phase != .active else { return }
        Self.log("incoming call ended before it was accepted in Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
        acceptWhenActive = false
    }

    private func connected() {
        if var call {
            call.phase = .active
            self.call = call
            Self.log("call connected")
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
            }
        }
    }

    private func disconnected() {
        guard let call, call.phase != .ringing else { return }
        Self.log("call ended in Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
        callFinished()
    }

    private func mutedInTeams(_ isMuted: Bool) {
        teamsMuted = isMuted
        guard let call, call.phase == .active, isMuted != muted else { return }
        Self.log("Teams \(isMuted ? "muted" : "unmuted"); updating CallKit")
        muted = isMuted
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.uuid, muted: isMuted))) { _ in }
    }

    private func callFinished() {
        muted = false
        teamsMuted = nil
        acceptWhenActive = false
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
        call = nil
        callFinished()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard var call, call.uuid == action.callUUID else {
            action.fail()
            return
        }
        call.phase = .answering
        self.call = call
        Self.log("answering")
        bridge.setRingtoneSuppressed(false)
        answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call, call.uuid == action.callUUID {
            // Still ringing in Teams if the accept was waiting for the app.
            let ringingInTeams = call.phase == .ringing || acceptWhenActive
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

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        muted = action.isMuted
        // Only a change made in the iOS call UI is applied to Teams. When the
        // action matches Teams' state it is Teams' own change coming back
        // from CallKit, and clicking would toggle the microphone again.
        if action.isMuted != teamsMuted {
            Self.log("iOS call UI \(action.isMuted ? "muted" : "unmuted"); applying to Teams")
            bridge.setMuted(action.isMuted)
        } else {
            Self.log("CallKit mute matches Teams (\(action.isMuted ? "muted" : "unmuted")); nothing to do")
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        acceptAfterHandOver()
        if call == nil {
            callFinished()
        }
    }
}
