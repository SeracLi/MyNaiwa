//
//  ContentView.swift
//  MyNaiWa
//
//  MVP interaction loop:
//    idle ↻ — occasionally interleaved with belly/head fillers (never adjacent)
//    tap upper body → 大笑; during 大笑, tap anywhere → idle
//    tap lower body → 浮起来 (non-interruptible)
//    tap left/right edge → 摸肚子 / 挠头 (idle only, non-interruptible)
//    press record button → 录音 → 奶蛙化重放 (talk mode)
//
//  Transitions cross-fade for ~80ms via layer alpha so AI-generated
//  brightness/exposure mismatches at clip seams become invisible.
//

import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - Clip catalog

enum NaiwaClip: String, CaseIterable {
    case idle       = "静默"
    case belly      = "摸肚子"
    case head       = "挠头"
    case gun        = "打枪"
    case taiji      = "打太极"
    case laugh      = "肚子和胳膊-大笑"
    case floating   = "腿与脚-浮起来"
    case talkEnter  = "进入"
    case talkListen = "聆听"
    case talkSpeak  = "说话"
    case talkExit   = "退出"

    /// Which subfolder under the bundle the clip lives in.
    var subdirectory: String {
        switch self {
        case .talkEnter, .talkListen, .talkSpeak, .talkExit: return "video/变声模式"
        case .taiji: return "video/可配动作"
        default: return "video"
        }
    }

    /// Talk-mode source videos are AI-generated and have stray audio we don't want.
    /// We only want奶蛙's own laugh sounds (in the 5 original clips) plus the
    /// pitch-shifted user recording (played through a separate engine) audible.
    var muteVideoAudio: Bool {
        switch self {
        case .talkEnter, .talkListen, .talkSpeak, .talkExit: return true
        default: return false
        }
    }
}

// MARK: - Configurable actions (right-side tap)

/// A right-arm action the user can equip. Tapping奶蛙's left arm (screen right)
/// plays the currently-equipped one. This is the collection/monetization slot:
/// future actions arrive as data here, gated by owned/price/source.
struct NaiwaAction: Identifiable {
    let id: String
    let name: String
    let clip: NaiwaClip
    let symbol: String      // SF Symbol for the collection card
    let owned: Bool         // prototype: everything owned; later: ad/coin/IAP

    static let catalog: [NaiwaAction] = [
        NaiwaAction(id: "gun",   name: "打枪",   clip: .gun,   symbol: "scope",                 owned: true),
        NaiwaAction(id: "taiji", name: "打太极", clip: .taiji, symbol: "figure.mind.and.body",  owned: true),
    ]

    static func byId(_ id: String) -> NaiwaAction? { catalog.first { $0.id == id } }
    static let defaultId = "gun"
}

// MARK: - State machine

enum NaiwaState: Equatable {
    case idle
    case fillerBelly
    case fillerHead
    case action         // equipped right-arm action (打枪 / 打太极 / …)
    case laugh
    case floating
    case talkEntering   // 进入 playing, recording started
    case listening      // 聆听 looping, recording in progress
    case speaking       // 说话 playing (looping if needed), audio playing back
    case talkExiting    // 退出 playing

    /// Tap-on-screen acceptance. Record button visibility is separate.
    var isInteractable: Bool {
        switch self {
        case .idle, .laugh: return true
        default: return false
        }
    }

    var isInTalkMode: Bool {
        switch self {
        case .talkEntering, .listening, .speaking, .talkExiting: return true
        default: return false
        }
    }
}

enum TapZone {
    case head          // 奶蛙的头 → 挠头
    case leftEdge      // → 摸肚子
    case rightEdge     // 奶蛙左手（画面右侧）→ 打枪（可购买动作位）
    case upperMiddle   // → 大笑
    case lowerMiddle   // → 浮起来
}

// MARK: - Host UIView (holds all AVPlayerLayers as stacked sublayers)

final class NaiwaHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in (layer.sublayers ?? []) where sublayer is AVPlayerLayer {
            sublayer.frame = bounds
        }
        CATransaction.commit()
    }
}

// MARK: - Voice (record + pitch-shift playback)

/// Distortion presets — a nil `avPreset` means "off".
enum DistortionPreset: String, CaseIterable, Identifiable {
    case none          = "无失真"
    case squared       = "粗暴失真"
    case decimated     = "复古降解"
    case brokenSpeaker = "破喇叭"
    case cosmic        = "宇宙干扰"
    case radioTower    = "老收音机"

    var id: String { rawValue }

    var avPreset: AVAudioUnitDistortionPreset? {
        switch self {
        case .none:          return nil
        case .squared:       return .multiDistortedSquared
        case .decimated:     return .multiDecimated1
        case .brokenSpeaker: return .multiBrokenSpeaker
        case .cosmic:        return .speechCosmicInterference
        case .radioTower:    return .speechRadioTower
        }
    }
}

/// A named bundle of voice-chain params. Tap to jump-set all sliders.
struct VoicePreset: Identifiable {
    let id: String
    let name: String
    let pitchCents: Float
    let distortion: DistortionPreset
    let distortionMix: Float
    let eqBassGain: Float
    let eqBassFreq: Float

    static let all: [VoicePreset] = [
        VoicePreset(id: "lsn",   name: "老水牛",   pitchCents: -700, distortion: .squared,    distortionMix: 22, eqBassGain: 4, eqBassFreq: 150),
        VoicePreset(id: "deep",  name: "低沉大叔", pitchCents: -500, distortion: .none,       distortionMix: 0,  eqBassGain: 3, eqBassFreq: 150),
        VoicePreset(id: "smoke", name: "粗糙烟嗓", pitchCents: -400, distortion: .radioTower, distortionMix: 25, eqBassGain: 2, eqBassFreq: 200),
        VoicePreset(id: "alien", name: "外星深沉", pitchCents: -800, distortion: .cosmic,     distortionMix: 28, eqBassGain: 0, eqBassFreq: 150),
        VoicePreset(id: "clean", name: "干净深沉", pitchCents: -600, distortion: .none,       distortionMix: 0,  eqBassGain: 5, eqBassFreq: 120),
        VoicePreset(id: "raw",   name: "原声",     pitchCents: 0,    distortion: .none,       distortionMix: 0,  eqBassGain: 0, eqBassFreq: 150),
    ]
}

@MainActor
final class NaiwaVoice: ObservableObject {

    /// Max recording length (seconds). Mirrors Tom Cat's ~10s cap.
    static let maxDuration: TimeInterval = 10.0

    // MARK: Tunable params (persisted). Safe to add latency now — the video
    // switch waits on the audible detector, so lip-sync holds regardless.

    /// Pitch shift in cents. Negative = deeper. 奶蛙 = coarse/粗犷.
    @Published var pitchCents: Float = -500 {
        didSet { pitchUnit.pitch = pitchCents; defaults.set(pitchCents, forKey: Keys.pitch) }
    }
    @Published var distortionPreset: DistortionPreset = .none {
        didSet { applyDistortionPreset(); defaults.set(distortionPreset.rawValue, forKey: Keys.distortion) }
    }
    @Published var distortionMix: Float = 0 {
        didSet { distortionUnit.wetDryMix = distortionMix; defaults.set(distortionMix, forKey: Keys.distortionMix) }
    }
    @Published var eqBassGain: Float = 0 {
        didSet { eqUnit.bands[0].gain = eqBassGain; defaults.set(eqBassGain, forKey: Keys.eqBassGain) }
    }
    @Published var eqBassFreq: Float = 150 {
        didSet { eqUnit.bands[0].frequency = eqBassFreq; defaults.set(eqBassFreq, forKey: Keys.eqBassFreq) }
    }

    /// Apple Voice Processing IO on the mic — noise suppression + echo cancel +
    /// AGC (the same pipeline FaceTime uses). This is the main "clean like Tom
    /// Cat" lever. Toggling reconfigures the engine (needs a stop/start).
    @Published var noiseReduction: Bool = true {
        didSet {
            guard oldValue != noiseReduction else { return }
            defaults.set(noiseReduction, forKey: Keys.noiseReduction)
            reconfigureVoiceProcessing()
        }
    }

    /// Presence lift — a high-shelf EQ boost (~4kHz) that makes the voice sit
    /// forward and sound crisp/clear rather than muffled. Runtime-safe (just an
    /// EQ band gain), no engine restart.
    @Published var voiceBoost: Bool = true {
        didSet {
            eqUnit.bands[1].gain = voiceBoost ? Self.presenceGain : 0
            defaults.set(voiceBoost, forKey: Keys.voiceBoost)
        }
    }
    private static let presenceGain: Float = 4.5   // dB @ high shelf

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let distortionUnit = AVAudioUnitDistortion()
    private let eqUnit = AVAudioUnitEQ(numberOfBands: 2)

    /// True once at least one recording exists — drives the preview button.
    var hasRecording: Bool {
        guard let buf = recordingBuffer else { return false }
        return buf.frameLength > 0
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let pitch          = "naiwa_voice_pitchCents"
        static let distortion     = "naiwa_voice_distortionPreset"
        static let distortionMix  = "naiwa_voice_distortionMix"
        static let eqBassGain     = "naiwa_voice_eqBassGain"
        static let eqBassFreq     = "naiwa_voice_eqBassFreq"
        static let noiseReduction = "naiwa_voice_noiseReduction"
        static let voiceBoost     = "naiwa_voice_voiceBoost"
    }

    private var recordingBuffer: AVAudioPCMBuffer?
    private var recordingFormat: AVAudioFormat?
    private var recordingFrames: AVAudioFrameCount = 0
    private var maxFrames: AVAudioFrameCount = 0
    private var isRecording = false

    private var enginePrepared = false

    /// Fired when max duration auto-stops recording (button still held).
    var onMaxDurationReached: (() -> Void)?
    /// Fired when pitch-shifted playback finishes.
    var onPlaybackEnded: (() -> Void)?
    /// Fired the moment REAL audio first flows out the mixer (not when we call
    /// play(), but when sound is actually audible). Drives the speak-video
    /// switch so mouth movement lines up with sound instead of leading it.
    var onPlaybackAudible: (() -> Void)?

    init() {
        engine.attach(playerNode)
        engine.attach(pitchUnit)
        engine.attach(distortionUnit)
        engine.attach(eqUnit)

        // Band 0: low shelf (bass/thickness). Band 1: high shelf (presence).
        let bass = eqUnit.bands[0]
        bass.filterType = .lowShelf
        bass.bypass = false
        let presence = eqUnit.bands[1]
        presence.filterType = .highShelf
        presence.frequency = 4000
        presence.bypass = false

        // Restore persisted tuning (didSet pushes to units + re-persists).
        if defaults.object(forKey: Keys.pitch) != nil { pitchCents = defaults.float(forKey: Keys.pitch) }
        if let raw = defaults.string(forKey: Keys.distortion),
           let preset = DistortionPreset(rawValue: raw) { distortionPreset = preset }
        if defaults.object(forKey: Keys.distortionMix) != nil { distortionMix = defaults.float(forKey: Keys.distortionMix) }
        if defaults.object(forKey: Keys.eqBassGain) != nil { eqBassGain = defaults.float(forKey: Keys.eqBassGain) }
        if defaults.object(forKey: Keys.eqBassFreq) != nil { eqBassFreq = defaults.float(forKey: Keys.eqBassFreq) }
        if defaults.object(forKey: Keys.noiseReduction) != nil { noiseReduction = defaults.bool(forKey: Keys.noiseReduction) }
        if defaults.object(forKey: Keys.voiceBoost) != nil { voiceBoost = defaults.bool(forKey: Keys.voiceBoost) }

        // Apply presence gain to band 1 based on restored/default voiceBoost.
        eqUnit.bands[1].gain = voiceBoost ? Self.presenceGain : 0
    }

    /// Toggling noise reduction requires re-enabling Voice Processing on the
    /// input node, which can only change while the engine is stopped. Restart
    /// if it was running (only happens from the debug panel, never mid-record).
    private func reconfigureVoiceProcessing() {
        guard enginePrepared else { return }   // will be applied at first setup
        let wasRunning = engine.isRunning
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(noiseReduction)
        if wasRunning { try? engine.start() }
    }

    func applyVoicePreset(_ preset: VoicePreset) {
        pitchCents       = preset.pitchCents
        distortionPreset = preset.distortion
        distortionMix    = preset.distortionMix
        eqBassGain       = preset.eqBassGain
        eqBassFreq       = preset.eqBassFreq
    }

    private func applyDistortionPreset() {
        if let preset = distortionPreset.avPreset {
            distortionUnit.loadFactoryPreset(preset)
        }
        // wetDryMix stays a separate control — don't clobber the user's slider.
    }

    /// Ask for mic permission. Returns granted state.
    /// Uses AVAudioApplication (iOS 17+) — the old AVAudioSession.requestRecord-
    /// Permission is deprecated. Deployment target is 17.6 so no fallback needed.
    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Switch to record category for a talk session. We only hold
    /// .playAndRecord WHILE talking — at rest we stay in .playback so the
    /// output volume can sit at 0 (iOS won't let a record-category session be
    /// fully muted; it auto-bumps the volume, which looked like "volume rising
    /// by itself" when the app idled). Forcing the built-in mic keeps AirPods
    /// on A2DP (not the HFP call route), which is what avoids the volume HUD.
    private func activateRecordSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            do {
                try session.setCategory(.playAndRecord,
                                        mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
            } catch {
                print("⚠️ audio session config: \(error)")
                return false
            }
        }
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        return true
    }

    /// Configure session + connect nodes + start engine. Idempotent.
    func enterTalkMode() -> Bool {
        guard activateRecordSession() else { return false }

        if !enginePrepared {
            // Enable Apple Voice Processing (noise suppression + AGC) on the mic
            // before reading formats. Safe for lip-sync now: the video switch
            // waits on the audible detector, so any added latency is absorbed.
            try? engine.inputNode.setVoiceProcessingEnabled(noiseReduction)

            let inFmt = engine.inputNode.outputFormat(forBus: 0)
            // Chain: player → pitch → distortion → EQ → mixer.
            // The extra units add a little latency, but the video switch waits
            // on the audible detector (installAudibleDetector), so lip-sync is
            // unaffected — the mouth still opens exactly when sound comes out.
            engine.connect(playerNode,     to: pitchUnit,            format: inFmt)
            engine.connect(pitchUnit,      to: distortionUnit,       format: inFmt)
            engine.connect(distortionUnit, to: eqUnit,               format: inFmt)
            engine.connect(eqUnit,         to: engine.mainMixerNode, format: inFmt)
            enginePrepared = true

            pitchUnit.pitch           = pitchCents
            distortionUnit.wetDryMix  = distortionMix
            eqUnit.bands[0].gain      = eqBassGain
            eqUnit.bands[0].frequency = eqBassFreq
            applyDistortionPreset()
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("⚠️ engine start: \(error)")
                return false
            }
        }
        return true
    }

    /// End a talk session: stop the engine and return the session to .playback
    /// so the output volume can rest at 0 again (record category forbids full
    /// mute). Built-in-mic routing kept AirPods on A2DP, so this category swap
    /// no longer triggers the volume HUD it used to.
    func exitTalkMode() {
        engine.mainMixerNode.removeTap(onBus: 0)
        onPlaybackAudible = nil
        playerNode.stop()
        engine.stop()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: Record

    func startRecording() {
        guard !isRecording else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        recordingFormat = format

        maxFrames = AVAudioFrameCount(format.sampleRate * Self.maxDuration)
        recordingBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)
        recordingFrames = 0
        isRecording = true

        inputNode.removeTap(onBus: 0)   // defensive
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            Task { @MainActor [weak self] in
                self?.appendRecording(buf)
            }
        }
    }

    private func appendRecording(_ src: AVAudioPCMBuffer) {
        guard isRecording, let dest = recordingBuffer else { return }
        let toCopy = min(src.frameLength, maxFrames - recordingFrames)
        if toCopy == 0 {
            // Filled to cap — auto-stop and notify.
            stopRecording()
            onMaxDurationReached?()
            return
        }
        if let srcCh = src.floatChannelData, let dstCh = dest.floatChannelData {
            let dstOffset = Int(recordingFrames)
            let channels = Int(dest.format.channelCount)
            for ch in 0..<channels {
                let srcIdx = min(ch, Int(src.format.channelCount) - 1)
                let s = srcCh[srcIdx]
                let d = dstCh[ch]
                for i in 0..<Int(toCopy) { d[dstOffset + i] = s[i] }
            }
        }
        recordingFrames += toCopy
        dest.frameLength = recordingFrames
    }

    /// Stop recording. Returns duration in seconds.
    @discardableResult
    func stopRecording() -> TimeInterval {
        guard isRecording else { return currentDuration }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        return currentDuration
    }

    private var currentDuration: TimeInterval {
        guard let fmt = recordingFormat, fmt.sampleRate > 0 else { return 0 }
        return TimeInterval(recordingFrames) / fmt.sampleRate
    }

    // MARK: Play

    /// Plays the recording back through the voice chain, but only if VAD finds
    /// real speech. Returns false when there's nothing worth mimicking (snap /
    /// silence / noise) so the caller can skip the speak animation entirely.
    @discardableResult
    func playRecording() -> Bool {
        guard let buf = speechTrimmedRecording(), buf.frameLength > 0 else {
            return false   // no speech — caller returns奶蛙 to idle
        }
        pitchUnit.pitch = pitchCents
        installAudibleDetector()
        playerNode.stop()
        playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPlaybackEnded?()
            }
        }
        playerNode.play()
        return true
    }

    /// Installs a one-shot tap on the mixer that fires `onPlaybackAudible` the
    /// first time real (non-silent) audio flows out — i.e. the true "sound is
    /// now audible" moment, which lags play() by the output + FFT-priming
    /// latency (~150-350ms). The video switch keys off this so mouth movement
    /// starts WITH the sound, not before it. The tap removes itself after firing.
    private func installAudibleDetector() {
        let mixer = engine.mainMixerNode
        let fmt = mixer.outputFormat(forBus: 0)
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var peak: Float = 0
            let c0 = ch[0]
            var i = 0
            while i < n { peak = max(peak, abs(c0[i])); i += 1 }
            guard peak > 0.003 else { return }   // still silence — keep waiting
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engine.mainMixerNode.removeTap(onBus: 0)
                self.onPlaybackAudible?()
                self.onPlaybackAudible = nil
            }
        }
    }

    /// Voice-activity detection over the recording. Returns a buffer trimmed
    /// to just before speech onset, or nil if no SUSTAINED speech was found.
    ///
    /// Rejects (→ nil):
    ///   • pure silence (user held the button but never spoke)
    ///   • transients like finger snaps / claps (energy spike < ~140ms)
    ///   • low steady room noise
    ///
    /// Method: split into 20ms frames, compute per-frame RMS, estimate the
    /// noise floor as a low percentile (robust to speech frames), then require
    /// a run of consecutive frames that are both above an absolute minimum AND
    /// ~10dB over the noise floor. The first such run marks speech onset.
    ///
    /// This is a lightweight energy+duration VAD — enough to reject the common
    /// non-speech cases. It does NOT discriminate speech from sustained noise
    /// (music, TV); that would need Sound Analysis or a real VAD model.
    private func speechTrimmedRecording() -> AVAudioPCMBuffer? {
        guard let buf = recordingBuffer, buf.frameLength > 0,
              let src = buf.floatChannelData else { return nil }

        let channels = Int(buf.format.channelCount)
        let totalFrames = Int(buf.frameLength)
        let sampleRate = buf.format.sampleRate

        let frameLen = max(1, Int(sampleRate * 0.02))     // 20ms analysis frame
        let nFrames = totalFrames / frameLen
        guard nFrames >= 1 else { return nil }

        // Per-frame RMS (channel 0 is representative enough).
        let c0 = src[0]
        var rms = [Float](repeating: 0, count: nFrames)
        for f in 0..<nFrames {
            let base = f * frameLen
            var sum: Float = 0
            for i in 0..<frameLen {
                let s = c0[base + i]
                sum += s * s
            }
            rms[f] = (sum / Float(frameLen)).squareRoot()
        }

        // Noise floor = 10th-percentile frame energy (won't be dragged up by
        // the loud speech frames). Speech threshold sits well above it.
        let sorted = rms.sorted()
        let noiseFloor = sorted[max(0, min(sorted.count - 1, sorted.count / 10))]
        let threshold = max(0.015, noiseFloor * 3.0)      // ~+10dB over noise

        // First run of >= minVoiceFrames consecutive above-threshold frames.
        let minVoiceFrames = 7                             // ~140ms sustained
        var run = 0
        var onsetFrame = -1
        for f in 0..<nFrames {
            if rms[f] > threshold {
                if run == 0 { onsetFrame = f }
                run += 1
                if run >= minVoiceFrames { break }
            } else {
                run = 0
                onsetFrame = -1
            }
        }
        guard run >= minVoiceFrames, onsetFrame >= 0 else {
            return nil   // no sustained speech — snap / silence / brief noise
        }

        // 60ms pre-roll so the first syllable's attack isn't clipped.
        let preRoll = Int(sampleRate * 0.06)
        let startSample = max(0, onsetFrame * frameLen - preRoll)
        if startSample <= 0 { return buf }                 // speech at the very start

        let newLen = AVAudioFrameCount(totalFrames - startSample)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: newLen),
              let dst = trimmed.floatChannelData else { return buf }
        trimmed.frameLength = newLen
        for ch in 0..<channels {
            let s = src[ch]; let d = dst[ch]
            for i in 0..<Int(newLen) { d[i] = s[startSample + i] }
        }
        return trimmed
    }

    func stopPlayback() {
        engine.mainMixerNode.removeTap(onBus: 0)
        onPlaybackAudible = nil
        playerNode.stop()
    }

    /// Re-plays the last recording through the current chain so the tuning
    /// panel can preview parameter changes without re-recording. Warms the
    /// engine into talk mode if it isn't running. Bypasses the VAD gate — the
    /// user explicitly asked to hear it, so play whatever's there.
    func replayLastRecording() {
        guard let buf = recordingBuffer, buf.frameLength > 0 else { return }
        if !engine.isRunning { _ = enterTalkMode() }
        pitchUnit.pitch = pitchCents
        playerNode.stop()
        playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack, completionHandler: nil)
        playerNode.play()
    }
}

// MARK: - Player

@MainActor
final class NaiwaPlayer: ObservableObject {
    let hostView = NaiwaHostView()
    let voice = NaiwaVoice()

    @Published private(set) var state: NaiwaState = .idle

    /// Record button is always enabled. Pressing it from ANY state interrupts
    /// whatever奶蛙 is doing (filler, laugh, floating, even mid-speak) and jumps
    /// straight into talk mode. Keeping it always-enabled also removes the
    /// jarring "button dims then un-dims on its own" flicker as clips change.
    var recordButtonEnabled: Bool { true }

    /// True while we're actively capturing audio — drives button color.
    var isRecording: Bool {
        state == .talkEntering || state == .listening
    }

    private var players: [NaiwaClip: AVPlayer] = [:]
    private var layers: [NaiwaClip: AVPlayerLayer] = [:]
    private var endObservers: [NaiwaClip: NSObjectProtocol] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var currentClip: NaiwaClip = .idle
    private var lastFiller: NaiwaClip?

    /// Guards the action rewind seek — while a seek is resolving, extra taps
    /// are dropped so rapid tapping doesn't pile up seeks and stutter.
    private var actionSeeking = false
    /// How far each right-side tap rewinds the current action (seconds).
    private let actionRewindStep: TimeInterval = 0.5

    /// The equipped right-arm action, persisted. Tapping奶蛙's left arm plays it.
    @Published var equippedActionId: String = NaiwaAction.defaultId {
        didSet { UserDefaults.standard.set(equippedActionId, forKey: "naiwa_equippedAction") }
    }
    private var equippedClip: NaiwaClip {
        NaiwaAction.byId(equippedActionId)?.clip ?? .gun
    }

    /// KVO tokens kept alive so we can preroll each clip once its item is ready.
    private var prewarmObservers: [NSKeyValueObservation] = []

    // Talk-mode bookkeeping
    private var isButtonHeld = false
    /// User released during talkEntering — finalize once enter clip finishes.
    private var pendingFinalize = false
    /// True between finalize and the moment audio becomes audible — during this
    /// window奶蛙 stays in the listening pose so the mouth doesn't lead the sound.
    private var pendingSpeakStart = false
    private var lastRecordingDuration: TimeInterval = 0
    private var talkModeReady = false

    init() {
        for clip in NaiwaClip.allCases {
            let p = AVPlayer()
            p.actionAtItemEnd = .pause
            if clip.muteVideoAudio { p.volume = 0 }
            let l = AVPlayerLayer(player: p)
            l.videoGravity = .resizeAspectFill
            l.isHidden = (clip != .idle)
            hostView.layer.addSublayer(l)
            players[clip] = p
            layers[clip] = l

            if let url = url(for: clip) {
                let item = AVPlayerItem(url: url)
                p.replaceCurrentItem(with: item)
                attachEndObserver(for: clip, item: item)
            } else {
                print("⚠️ Missing video: \(clip.rawValue).mp4")
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "naiwa_equippedAction"),
           NaiwaAction.byId(saved) != nil {
            equippedActionId = saved
        }
        setupLifecycle()
        wireVoice()
        players[.idle]?.play()
        prewarmDecoders()
    }

    deinit {
        endObservers.values.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        prewarmObservers.forEach { $0.invalidate() }
    }

    // MARK: Decoder prewarm

    /// Prime every paused clip's decode pipeline once its item is ready, so the
    /// FIRST real playback is already "hot". This kills the occasional
    /// first-play glitch where B-frame decode reordering briefly shows an
    /// earlier frame (most visible on the 聆听 clip, which was re-encoded in
    /// Premiere). `preroll` fills buffers without advancing or making sound.
    private func prewarmDecoders() {
        for (clip, player) in players {
            // idle is already playing (warm); everything else is paused.
            guard clip != .idle, let item = player.currentItem else { continue }
            if item.status == .readyToPlay {
                player.preroll(atRate: 1.0)
            } else {
                let obs = item.observe(\.status, options: [.new]) { [weak player] observed, _ in
                    guard observed.status == .readyToPlay else { return }
                    Task { @MainActor [weak player] in player?.preroll(atRate: 1.0) }
                }
                prewarmObservers.append(obs)
            }
        }
    }

    // MARK: Bundle lookup

    private func url(for clip: NaiwaClip) -> URL? {
        Bundle.main.url(forResource: clip.rawValue, withExtension: "mp4", subdirectory: clip.subdirectory)
            ?? Bundle.main.url(forResource: clip.rawValue, withExtension: "mp4", subdirectory: "video")
            ?? Bundle.main.url(forResource: clip.rawValue, withExtension: "mp4")
    }

    // MARK: Observers

    private func attachEndObserver(for clip: NaiwaClip, item: AVPlayerItem) {
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onClipEnded(clip) }
        }
        endObservers[clip] = obs
    }

    private func setupLifecycle() {
        let bg = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.players[self?.currentClip ?? .idle]?.pause()
            }
        }
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverFromBackground()
            }
        }
        lifecycleObservers = [bg, fg]
    }

    /// Returning from background, AVPlayerLayers often go blank — the render
    /// server dropped their surfaces and a bare `play()` won't repaint them.
    /// Fix: re-attach every layer's player (the documented workaround), reset
    /// all clips to frame 0, then cleanly resume the idle loop. Any interrupted
    /// talk-mode flow is abandoned (recording/playback can't survive a
    /// background transition), so we always land in a known-good idle state.
    private func recoverFromBackground() {
        if state.isInTalkMode {
            voice.stopPlayback()
        }
        isButtonHeld = false
        pendingFinalize = false
        pendingSpeakStart = false

        // Re-attach + rewind every player so none of them are stuck blank.
        for (clip, player) in players {
            let layer = layers[clip]
            layer?.player = nil
            layer?.player = player
            layer?.isHidden = (clip != .idle)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if clip != .idle { player.pause() }
        }

        state = .idle
        currentClip = .idle
        players[.idle]?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.players[.idle]?.play() }
        }
    }

    private func wireVoice() {
        voice.onMaxDurationReached = { [weak self] in
            Task { @MainActor [weak self] in self?.handleMaxRecordingReached() }
        }
        voice.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.handleAudioPlaybackEnded() }
        }
    }

    // MARK: Clip-end dispatch

    private func onClipEnded(_ clip: NaiwaClip) {
        guard clip == currentClip else {
            // Stale end — this clip ended in background after we transitioned
            // away. Reset it to frame 0 for next time. Safe because the layer
            // is already hidden, so the seek's visual update is invisible.
            players[clip]?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        // Active case: do NOT seek here. The clip is still visible. Seeking
        // would race with the upcoming switchTo's CATransaction and the user
        // briefly sees this clip's frame 0 before the layer is hidden.
        // (Was the cause of the "flash of 思考 pose after talk session" bug.)
        // switchTo will reset this player to zero after it hides the layer.

        switch state {
        case .idle:
            if Bool.random() {
                let next: NaiwaClip = (lastFiller == .belly) ? .head : .belly
                lastFiller = next
                state = (next == .belly) ? .fillerBelly : .fillerHead
                switchTo(next)
            } else {
                switchTo(.idle)
            }
        case .fillerBelly, .fillerHead, .action, .laugh, .floating:
            state = .idle
            switchTo(.idle)
        case .talkEntering:
            // Enter clip done — decide based on whether user is still holding.
            if pendingFinalize {
                pendingFinalize = false
                finalizePlayback()
            } else if isButtonHeld {
                state = .listening
                switchTo(.talkListen)
            } else {
                // Edge: button released but pendingFinalize wasn't set (shouldn't
                // happen, but safe-guard). Treat as cancel.
                state = .talkExiting
                switchTo(.talkExit)
            }
        case .listening:
            // Loop the listen clip while user keeps holding.
            switchTo(.talkListen)
        case .speaking:
            if pendingSpeakStart {
                // Audio hasn't become audible yet — keep looping the listening
                // pose so the mouth doesn't start moving before there's sound.
                switchTo(.talkListen)
            } else {
                // Audio still playing — loop the speak clip until it ends.
                switchTo(.talkSpeak)
            }
        case .talkExiting:
            state = .idle
            switchTo(.idle)
            // Defer audio session swap. AVAudioSession.setActive is synchronous
            // and can block the main thread for 10-50ms — doing it inline causes
            // a visible stutter right when idle's first frame should render.
            // 100ms is enough for the layer swap to be on screen by the time
            // the setActive hit lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                // Bail if the user re-pressed record during the exit window —
                // otherwise we'd tear down the session/engine mid new-recording.
                guard let self, self.state == .idle else { return }
                self.voice.exitTalkMode()
            }
        }
    }

    // MARK: Switch — crossfade visibility swap

    private func switchTo(_ next: NaiwaClip) {
        let from = currentClip

        if next == from {
            // Same-clip loop (idle / listen / speak). Synchronous seek + play
            // so play() doesn't race a fire-and-forget seek and briefly show
            // the clip's tail before jumping to zero.
            let p = players[from]
            p?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Bail if we've moved to a different clip during the seek.
                    // Otherwise the orphan play() leaves this player advancing
                    // in the background; next time it's shown it'll be at the
                    // wrong frame.
                    guard let self, self.currentClip == from else { return }
                    p?.play()
                }
            }
            return
        }

        let oldPlayer = players[from]
        let oldLayer  = layers[from]
        let newPlayer = players[next]
        let newLayer  = layers[next]

        // Atomic visibility swap inside a single CATransaction with implicit
        // animations disabled. The old player's seek-to-zero MUST come after
        // the commit so the seek's visual update lands on an already-hidden
        // layer — otherwise the layer briefly shows the old clip's frame 0.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newPlayer?.play()
        newLayer?.isHidden = false
        oldLayer?.isHidden = true
        oldPlayer?.pause()
        CATransaction.commit()

        oldPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

        currentClip = next
    }

    // MARK: Tap dispatch (existing flow — unchanged)

    func handleTap(_ zone: TapZone) {
        // Experimental: tapping the right side WHILE an action is playing
        // rewinds it ~0.5s and keeps going (e.g. "keep shooting"). This is the
        // one interruptible filler; it happens before the isInteractable gate.
        if state == .action, zone == .rightEdge {
            rewindAction()
            return
        }

        guard state.isInteractable else { return }

        if state == .laugh {
            state = .idle
            switchTo(.idle)
            return
        }

        switch zone {
        case .head:
            state = .fillerHead
            lastFiller = .head
            switchTo(.head)
        case .leftEdge:
            state = .fillerBelly
            lastFiller = .belly
            switchTo(.belly)
        case .rightEdge:
            state = .action
            switchTo(equippedClip)
        case .upperMiddle:
            state = .laugh
            switchTo(.laugh)
        case .lowerMiddle:
            state = .floating
            switchTo(.floating)
        }
    }

    /// Rewind the currently-playing action by `actionRewindStep`, clamped at
    /// frame 0, and keep playing. The `actionSeeking` guard drops taps that
    /// arrive while a seek is still resolving — that's what keeps rapid tapping
    /// from stacking seeks and stuttering. A small tolerance keeps the rewind
    /// snappy rather than frame-accurate (better feel for a "keep going" tap).
    private func rewindAction() {
        guard state == .action, !actionSeeking, let p = players[currentClip] else { return }
        let cur = CMTimeGetSeconds(p.currentTime())
        guard cur.isFinite else { return }
        let target = max(0, cur - actionRewindStep)
        let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
        actionSeeking = true
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.actionSeeking = false
                // Still mid-action? keep it rolling (seek can leave rate at 0).
                if self.state == .action, let p = self.players[self.currentClip], p.rate == 0 {
                    p.play()
                }
            }
        }
    }

    // MARK: Talk mode — record button hooks

    func recordButtonPressed() {
        // Allowed from ANY state except while already recording (holding).
        guard state != .talkEntering, state != .listening else { return }

        // An interrupt = pressed while奶蛙 was doing something OTHER than idle.
        // In that case skip the 进入 clip (its arms-down→托腮 motion looks
        // redundant coming from another pose) and jump straight to listening.
        let isInterrupt = (state != .idle)

        // Stop any speaking-audio and clear pending transitions.
        voice.stopPlayback()
        pendingSpeakStart = false
        pendingFinalize = false

        if talkModeReady {
            // Fast path — fully synchronous, no race window for stale callbacks.
            _ = voice.enterTalkMode()
            beginTalk(interrupt: isInterrupt)
        } else {
            // First time: request mic permission (async). Hold state so a
            // stale audio-end callback can't send us down the exit path.
            state = .talkEntering
            Task { @MainActor in
                let granted = await voice.requestMicPermission()
                guard granted, voice.enterTalkMode() else {
                    print("⚠️ mic permission denied / talk-mode failed")
                    state = .idle
                    switchTo(.idle)
                    return
                }
                talkModeReady = true
                beginTalk(interrupt: isInterrupt)
            }
        }
    }

    /// Common tail of recordButtonPressed once the engine/session is live.
    /// Fresh start from idle plays the 进入 clip; an interrupt jumps straight
    /// into the listening loop.
    private func beginTalk(interrupt: Bool) {
        isButtonHeld = true
        pendingFinalize = false
        voice.startRecording()
        if interrupt {
            state = .listening
            switchTo(.talkListen)
        } else {
            state = .talkEntering
            switchTo(.talkEnter)
        }
    }

    func recordButtonReleased() {
        guard isButtonHeld else { return }
        isButtonHeld = false
        lastRecordingDuration = voice.stopRecording()

        if state == .listening {
            finalizePlayback()
        } else if state == .talkEntering {
            // Wait for entry clip to finish, then finalize.
            pendingFinalize = true
        }
    }

    private func handleMaxRecordingReached() {
        guard isButtonHeld else { return }
        isButtonHeld = false
        lastRecordingDuration = NaiwaVoice.maxDuration
        if state == .listening {
            finalizePlayback()
        } else if state == .talkEntering {
            pendingFinalize = true
        }
    }

    private func handleAudioPlaybackEnded() {
        guard state == .speaking else { return }
        state = .talkExiting
        switchTo(.talkExit)
    }

    private func finalizePlayback() {
        // Too short to be useful — skip playback, just play exit and bail.
        if lastRecordingDuration < 0.3 {
            state = .talkExiting
            switchTo(.talkExit)
            return
        }
        state = .speaking
        // Stay in the listening pose. Don't switch to the speak clip until the
        // audio is ACTUALLY audible (playback startup latency ~150-350ms).
        // Otherwise奶蛙's mouth moves during the silent warm-up gap.
        pendingSpeakStart = true
        voice.onPlaybackAudible = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSpeakStart else { return }
                self.pendingSpeakStart = false
                self.switchTo(.talkSpeak)
            }
        }

        // VAD gate: if no real speech was recorded (finger snap, silence, brief
        // noise),奶蛙 shouldn't mimic anything — go straight back to idle.
        guard voice.playRecording() else {
            pendingSpeakStart = false
            voice.onPlaybackAudible = nil
            state = .talkExiting
            switchTo(.talkExit)
            return
        }

        // Fallback: if the audible detector never fires (e.g. a quiet recording
        // under the mixer threshold), switch anyway after 400ms so奶蛙 doesn't
        // get stuck looping the listening pose forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.pendingSpeakStart, self.state == .speaking else { return }
            self.pendingSpeakStart = false
            self.switchTo(.talkSpeak)
        }
    }
}

// MARK: - Debug / tuning panel

struct DebugPanel: View {
    @ObservedObject var voice: NaiwaVoice
    @Binding var showHitZones: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("视觉调试") {
                    Toggle("显示交互区域（红/蓝/绿/紫）", isOn: $showHitZones)
                    Text("勾上后关闭本页，主屏幕会显示 4 个交互区域色块")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("清晰度") {
                    Toggle("降噪（去环境音）", isOn: $voice.noiseReduction)
                    Text("苹果 Voice Processing：抑制环境噪音 + 回声 + 自动增益")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("人声增强（更清亮）", isOn: $voice.voiceBoost)
                    Text("高频提升，让声音更靠前、更清楚（类似汤姆猫的通透感）")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("音色预设（点一下直接套用）") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(VoicePreset.all) { preset in
                            Button {
                                voice.applyVoicePreset(preset)
                            } label: {
                                Text(preset.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("音高") {
                    HStack {
                        Text("\(Int(voice.pitchCents)) cents")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $voice.pitchCents, in: -2000...1200, step: 25)
                    }
                    Text("负数变沉、正数变尖。奶蛙适合 -400 ~ -800")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("失真（粗糙感）") {
                    Picker("类型", selection: $voice.distortionPreset) {
                        ForEach(DistortionPreset.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    HStack {
                        Text("湿度 \(Int(voice.distortionMix))%")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $voice.distortionMix, in: 0...100, step: 1)
                    }
                    Text("0 = 无失真。20-30 的沙哑感通常最舒服")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("低频增益（厚度）") {
                    HStack {
                        Text("增益 \(String(format: "%+.0f", voice.eqBassGain)) dB")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $voice.eqBassGain, in: -12...12, step: 1)
                    }
                    HStack {
                        Text("频率 \(Int(voice.eqBassFreq)) Hz")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $voice.eqBassFreq, in: 60...500, step: 10)
                    }
                    Text("正值让声音更厚、更有胸腔感，60-200 Hz 是奶蛙甜区")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section {
                    Button {
                        voice.replayLastRecording()
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text(voice.hasRecording ? "用当前参数试听刚才的录音" : "先录一次奶蛙才能试听")
                            Spacer()
                        }
                    }
                    .disabled(!voice.hasRecording)
                }

                Section {
                    Button(role: .destructive) {
                        if let raw = VoicePreset.all.first(where: { $0.id == "raw" }) {
                            voice.applyVoicePreset(raw)
                        }
                    } label: {
                        Text("清零（回到原声）")
                    }
                }
            }
            .navigationTitle("调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var naiwa = NaiwaPlayer()
    @State private var showHitZones = false
    @State private var showDebug = false
    @State private var showActions = false

    private let edgeFraction: CGFloat = 0.18
    private let upperBodyFraction: CGFloat = 0.60

    /// 奶蛙's head, expressed in VIDEO-normalized coords (0-1 within the 9:16
    /// source frame), NOT screen coords. Taps are mapped back through the
    /// aspect-fill transform before testing, so this stays correct on both
    /// iPhone and iPad regardless of how the video is cropped to fit.
    /// Generously sized per request — better to over-cover the head a bit.
    private let headRect = CGRect(x: 0.26, y: 0.12, width: 0.34, height: 0.28)

    /// All clips are 9:16 (720×1280 and 1792×3184 both ≈ 0.5625 w/h).
    private let videoAspect: CGFloat = 9.0 / 16.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                NaiwaSurface(view: naiwa.hostView)
                    .ignoresSafeArea()

                if showHitZones {
                    debugOverlay(in: geo.size)
                }

                // Top chrome: dev debug (left) + user settings placeholder (right).
                VStack {
                    HStack {
                        // Dev-only debug entry — distinct icon so it reads as a
                        // tool, not a user setting. Gate/hide before shipping.
                        circleIconButton("ladybug.fill", size: 17) { showDebug = true }
                            .padding(.leading, 14)
                        Spacer()
                        // User-facing settings — placeholder, no action yet.
                        circleIconButton("line.3.horizontal", size: 19) { }
                            .padding(.trailing, 14)
                    }
                    .padding(.top, 12)
                    Spacer()
                }

                // Bottom chrome: record (center) + actions/collection (right).
                VStack(spacing: 10) {
                    Spacer()
                    Text(hintText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 1)
                        .animation(.easeInOut(duration: 0.18), value: naiwa.state)
                        .frame(height: 18)   // fixed height so button doesn't jump

                    ZStack {
                        RecordButton(
                            isActive:  naiwa.isRecording,
                            isEnabled: naiwa.recordButtonEnabled,
                            onPress:   { naiwa.recordButtonPressed() },
                            onRelease: { naiwa.recordButtonReleased() }
                        )
                        // Actions button sits to the right of the record button.
                        HStack {
                            Spacer()
                            Button { showActions = true } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "figure.run")
                                        .font(.system(size: 22, weight: .semibold))
                                    Text("动作")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(width: 58, height: 58)
                                .background(Color.black.opacity(0.30))
                                .clipShape(Circle())
                            }
                            .padding(.trailing, 26)
                        }
                    }
                }
                .padding(.bottom, 26)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        let zone = zone(for: event.location, in: geo.size)
                        naiwa.handleTap(zone)
                    }
            )
        }
        .statusBarHidden()
        .sheet(isPresented: $showDebug) {
            DebugPanel(voice: naiwa.voice, showHitZones: $showHitZones)
        }
        .sheet(isPresented: $showActions) {
            ActionCollectionView(
                equippedId: naiwa.equippedActionId,
                onEquip: { naiwa.equippedActionId = $0 }
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// Small translucent round icon button used for the top chrome.
    private func circleIconButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
                .padding(9)
                .background(Color.black.opacity(0.28))
                .clipShape(Circle())
        }
    }

    /// Copy that appears just above the record button. Changes with state to
    /// train users on the press-and-hold rhythm — critical because without it
    /// they tend to speak too early, before奶蛙 enters listening pose.
    private var hintText: String {
        switch naiwa.state {
        case .idle:         return "按住说话"
        case .talkEntering: return "奶蛙准备中…"
        case .listening:    return "说话吧 🎙️"
        default:            return " "   // preserved height, no visible text
        }
    }

    private func zone(for point: CGPoint, in size: CGSize) -> TapZone {
        // Head takes priority over the edge/middle split. Test in video space
        // so it lands on奶蛙's head on any device aspect ratio.
        if headRect.contains(videoNormalizedPoint(for: point, in: size)) {
            return .head
        }
        let leftMax  = size.width * edgeFraction
        let rightMin = size.width * (1 - edgeFraction)
        if point.x < leftMax  { return .leftEdge }
        if point.x > rightMin { return .rightEdge }
        return point.y < size.height * upperBodyFraction ? .upperMiddle : .lowerMiddle
    }

    /// The video's displayed rect on screen under `.resizeAspectFill` (it
    /// overflows the screen; the offset is negative on the cropped axis).
    private func displayedVideoRect(in size: CGSize) -> CGRect {
        let screenAspect = size.width / size.height
        var w = size.width, h = size.height
        if screenAspect > videoAspect {
            // Screen wider than video → fill width, crop top/bottom.
            w = size.width
            h = size.width / videoAspect
        } else {
            // Screen taller/narrower → fill height, crop sides.
            h = size.height
            w = size.height * videoAspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Screen point → video-normalized (0-1) coordinate, inverting aspect-fill.
    private func videoNormalizedPoint(for p: CGPoint, in size: CGSize) -> CGPoint {
        let r = displayedVideoRect(in: size)
        return CGPoint(x: (p.x - r.minX) / r.width,
                       y: (p.y - r.minY) / r.height)
    }

    /// Head hit-box mapped forward into screen coords (for the debug overlay).
    private func headScreenRect(in size: CGSize) -> CGRect {
        let r = displayedVideoRect(in: size)
        return CGRect(x: r.minX + headRect.minX * r.width,
                      y: r.minY + headRect.minY * r.height,
                      width: headRect.width * r.width,
                      height: headRect.height * r.height)
    }

    private func debugOverlay(in size: CGSize) -> some View {
        let edgeW = size.width * edgeFraction
        let upperH = size.height * upperBodyFraction
        let head = headScreenRect(in: size)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ZStack {
                    Color.green.opacity(0.20)
                    Text("摸肚子")
                        .foregroundColor(.white).font(.headline).shadow(radius: 4)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: edgeW)
                VStack(spacing: 0) {
                    ZStack {
                        Color.red.opacity(0.18)
                        Text("上半身 → 大笑")
                            .foregroundColor(.white).font(.headline).shadow(radius: 4)
                    }
                    .frame(height: upperH)
                    ZStack {
                        Color.blue.opacity(0.18)
                        Text("下半身 → 浮起来")
                            .foregroundColor(.white).font(.headline).shadow(radius: 4)
                    }
                }
                ZStack {
                    Color.purple.opacity(0.20)
                    Text("打枪")
                        .foregroundColor(.white).font(.headline).shadow(radius: 4)
                        .rotationEffect(.degrees(90))
                }
                .frame(width: edgeW)
            }

            // Head hit-box overlaid on top (highest priority zone).
            ZStack {
                Color.yellow.opacity(0.30)
                Text("头 → 挠头")
                    .foregroundColor(.black).font(.caption).bold()
            }
            .frame(width: head.width, height: head.height)
            .offset(x: head.minX, y: head.minY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Action collection (图鉴 / equip)

struct ActionCollectionView: View {
    let equippedId: String
    let onEquip: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("点击奶蛙的左手（屏幕右侧）会触发当前装备的动作")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(NaiwaAction.catalog) { action in
                        actionCard(action)
                    }
                    comingSoonCard
                }
                .padding(16)
            }
            .navigationTitle("动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func actionCard(_ action: NaiwaAction) -> some View {
        let isEquipped = action.id == equippedId
        return Button {
            guard action.owned else { return }   // future: buy / watch-ad flow
            onEquip(action.id)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isEquipped ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                    Image(systemName: action.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(action.owned ? .accentColor : .gray)
                    if !action.owned {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(8)
                    }
                }
                .frame(height: 88)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isEquipped ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(action.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)

                Text(isEquipped ? "装备中" : (action.owned ? "点击装备" : "未拥有"))
                    .font(.system(size: 11))
                    .foregroundColor(isEquipped ? .accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Teaser slot — signals more actions are coming (drives the collection loop).
    private var comingSoonCard: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundColor(Color(.systemGray3))
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundColor(.gray)
            }
            .frame(height: 88)
            Text("敬请期待")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("更多动作")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Record button (press-and-hold)

struct RecordButton: View {
    let isActive: Bool                  // manager is in recording phase
    let isEnabled: Bool                 // manager accepts press input right now
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false
    /// Toggled once in onAppear to kick off the perpetual halo pulse.
    @State private var haloPulse = false
    /// Deferred "commit to talk mode" work. A press only becomes a real
    /// listen session once held past `holdThreshold`; a quick tap cancels it.
    @State private var commitWork: DispatchWorkItem?
    /// True once we've actually committed (fired onPress) for this press.
    @State private var committed = false

    /// Minimum hold before we start listening. Below this = a tap → no effect
    /// (button still flashes, but奶蛙 doesn't react). Prevents accidental
    /// enter→exit flickers from stray taps.
    private let holdThreshold: TimeInterval = 0.18

    /// Visually "hot" = local press OR external recording state.
    private var isHot: Bool { isPressed || isActive }

    var body: some View {
        ZStack {
            // Perpetual pulse halo — invites the user to press when idle, and
            // signals "recording" when hot. scaleEffect+opacity+repeatForever
            // is the standard SwiftUI infinite-animation pattern.
            Circle()
                .stroke(isHot ? Color.red.opacity(0.55) : Color.white.opacity(0.35),
                        lineWidth: 2)
                .frame(width: 100, height: 100)
                .scaleEffect(haloPulse ? 1.28 : 1.0)
                .opacity(haloPulse ? 0 : 0.9)
                .animation(
                    .easeOut(duration: isHot ? 0.9 : 1.6).repeatForever(autoreverses: false),
                    value: haloPulse
                )
                .allowsHitTesting(false)

            // Base circle — top-lit linear gradient reads as a 3D pill.
            Circle()
                .fill(
                    LinearGradient(
                        colors: isHot
                            ? [Color(red: 1.00, green: 0.35, blue: 0.32),
                               Color(red: 0.72, green: 0.10, blue: 0.10)]
                            : [Color.white,
                               Color(white: 0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 84, height: 84)

            // Highlight ring — fades from white at top to transparent at
            // bottom, selling the "light source above" bevel.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(isHot ? 0.55 : 0.95),
                                 Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .frame(width: 84, height: 84)

            Image(systemName: "mic.fill")
                .font(.system(size: 33, weight: .bold))
                .foregroundColor(isHot ? .white : Color(white: 0.13))
                .shadow(color: .black.opacity(isHot ? 0.25 : 0), radius: 1, y: 1)
        }
        // Whole button "recesses" when pressed: slightly smaller + softer shadow.
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .shadow(
            color: .black.opacity(isPressed ? 0.15 : 0.35),
            radius: isPressed ? 4 : 12,
            x: 0,
            y: isPressed ? 2 : 7
        )
        .opacity(isEnabled ? 1.0 : 0.40)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .animation(.easeOut(duration: 0.20), value: isActive)
        .animation(.easeOut(duration: 0.20), value: isEnabled)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled else { return }
                    if !isPressed {
                        isPressed = true          // immediate visual feedback
                        committed = false
                        // Defer the real "start listening" until held long
                        // enough. A quick tap cancels this before it fires.
                        let work = DispatchWorkItem {
                            committed = true
                            onPress()
                        }
                        commitWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    commitWork?.cancel()
                    commitWork = nil
                    if committed {
                        committed = false
                        onRelease()
                    }
                    // else: released before threshold → it was a tap, no effect.
                }
        )
        .onAppear { haloPulse = true }
        .accessibilityLabel("按住录音")
    }
}

// MARK: - Host view representable

struct NaiwaSurface: UIViewRepresentable {
    let view: NaiwaHostView
    func makeUIView(context: Context) -> NaiwaHostView { view }
    func updateUIView(_ uiView: NaiwaHostView, context: Context) {}
}

#Preview {
    ContentView()
}
