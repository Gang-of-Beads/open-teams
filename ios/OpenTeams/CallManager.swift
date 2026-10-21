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
/// - Placed or joined calls and meetings: when Teams' calling screen appears
///   without a CallKit call, an outgoing call is started for it.
/// - End and Mute in the iOS UI click Teams' hang-up and microphone buttons;
///   muting in Teams is reflected back.
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
    private var call: Call?
    private var muted = false

    init(bridge: CallBridge, keepAlive: BackgroundKeepAlive) {
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
        provider.reportNewIncomingCall(with: uuid, update: Self.update(name: name, number: number)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                Self.log("incoming call not reported: \(error.localizedDescription)")
                guard let self, self.call?.uuid == uuid else { return }
                self.call = nil
                // Let Teams ring on its own instead.
                self.bridge.setRingtoneSuppressed(false)
            }
        }
    }

    private func incomingEnded() {
        // While answering, the toast disappears because we clicked accept.
        guard let call, call.phase == .ringing else { return }
        Self.log("incoming call ended before it was answered here")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
    }

    private func connected() {
        if var call {
            call.phase = .active
            self.call = call
            Self.log("call connected")
            return
        }
        // Placed or joined from Teams itself.
        let uuid = UUID()
        call = Call(uuid: uuid, phase: .active)
        let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: "Microsoft Teams"))
        controller.request(CXTransaction(action: start)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                Self.log("outgoing call not reported: \(error.localizedDescription)")
                guard let self, self.call?.uuid == uuid else { return }
                self.call = nil
                self.releaseAudioSession()
            }
        }
    }

    private func disconnected() {
        guard let call, call.phase != .ringing else { return }
        Self.log("call ended in Teams")
        provider.reportCall(with: call.uuid, endedAt: nil, reason: .remoteEnded)
        self.call = nil
        releaseAudioSession()
    }

    private func mutedInTeams(_ isMuted: Bool) {
        guard let call, call.phase == .active, isMuted != muted else { return }
        muted = isMuted
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.uuid, muted: isMuted))) { _ in }
    }

    // MARK: Audio session

    private func configureAudioSessionForCall() {
        keepAlive.callInProgress = true
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP]
            )
        } catch {
            Self.log("audio session not configured for the call: \(error.localizedDescription)")
        }
    }

    private func releaseAudioSession() {
        muted = false
        keepAlive.callInProgress = false
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
        releaseAudioSession()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard var call, call.uuid == action.callUUID else {
            action.fail()
            return
        }
        call.phase = .answering
        self.call = call
        Self.log("answering")
        configureAudioSessionForCall()
        bridge.setRingtoneSuppressed(false)
        bridge.answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call, call.uuid == action.callUUID {
            Self.log(call.phase == .ringing ? "declining" : "hanging up")
            if call.phase == .ringing {
                bridge.decline()
            } else {
                bridge.hangUp()
            }
            bridge.setRingtoneSuppressed(false)
            self.call = nil
            releaseAudioSession()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSessionForCall()
        action.fulfill()
        // Teams has already connected by the time this runs.
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        provider.reportCall(with: action.callUUID, updated: Self.update(name: "Microsoft Teams", number: ""))
        Self.log("call from Teams shown in CallKit")
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        muted = action.isMuted
        bridge.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        if call == nil {
            releaseAudioSession()
        }
    }
}
