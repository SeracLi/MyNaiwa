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
    case spacesuit  = "太空服"
    case gatling    = "加特林"
    case bread      = "吃面包"
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
        case .gun, .taiji, .spacesuit, .gatling, .bread: return "video/可配动作"
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
    let emoji: String       // fallback icon (toasts / assets without an image)
    let image: String       // Assets image name shown in the floating 动作 panel
    let tier: AssetTier     // 赠送 / 免费 / 礼包 / 隐藏 — drives unlock & uses

    static let catalog: [NaiwaAction] = [
        NaiwaAction(id: "taiji",     name: "打太极", clip: .taiji,     emoji: "🥋",  image: "太极",   tier: .gift),
        NaiwaAction(id: "spacesuit", name: "太空服", clip: .spacesuit, emoji: "🧑‍🚀", image: "宇航员", tier: .free),
        NaiwaAction(id: "bread",     name: "吃面包", clip: .bread,     emoji: "🍞",  image: "面包",   tier: .free),
        NaiwaAction(id: "gun",       name: "打枪",   clip: .gun,       emoji: "🔫",  image: "手枪",   tier: .pack),
        NaiwaAction(id: "gatling",   name: "加特林", clip: .gatling,   emoji: "💥",  image: "加特林", tier: .hidden),
    ]

    static func byId(_ id: String) -> NaiwaAction? { catalog.first { $0.id == id } }
    /// Default right-hand = NONE ("") → the right zone plays 挠头. Only ∞ actions
    /// can be equipped (via long-press), and long-pressing again unequips.
    static let defaultId = ""
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

    /// A clip driven by a body interaction (head/belly/laugh/floating/equipped
    /// action). These support "连续点击倒退继播": re-tapping their zone rewinds
    /// and keeps playing. NOTE: belly/head are shared with character-initiated
    /// fillers — the rewind is additionally gated by `interactionRewindZone`
    /// being non-nil, which only a USER tap sets, so self-motion stays inert.
    var isUserInteraction: Bool {
        switch self {
        case .fillerBelly, .fillerHead, .action, .laugh, .floating: return true
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
        VoicePreset(id: "raw",   name: "原声",     pitchCents: 0,    distortion: .none,       distortionMix: 0,  eqBassGain: 0,  eqBassFreq: 150),
        VoicePreset(id: "loli",  name: "萝莉音",   pitchCents: 700,  distortion: .none,       distortionMix: 0,  eqBassGain: -3, eqBassFreq: 200),
    ]
}

// MARK: - User-facing voices (音色切换)

/// A voice the *user* can switch between from the main screen (奶蛙原声 / 萝莉音).
/// Unlike the dev-only `VoicePreset`, a profile carries the FULL chain including
/// the clarity toggles (降噪 / 人声增强), so selecting one fully defines how奶蛙
/// sounds. This is also the future 语音包 monetization slot — new voices arrive
/// as data entries here, gated by owned/price later.
struct NaiwaVoiceProfile: Identifiable {
    let id: String
    let name: String
    let emoji: String               // Apple emoji shown in the floating 音色 panel
    let tier: AssetTier             // 赠送(原声) / 免费(萝莉音) — drives unlock & uses
    let pitchCents: Float
    let distortion: DistortionPreset
    let distortionMix: Float
    let eqBassGain: Float
    let eqBassFreq: Float
    let noiseReduction: Bool
    let voiceBoost: Bool

    static let all: [NaiwaVoiceProfile] = [
        NaiwaVoiceProfile(id: "naiwa", name: "奶蛙原声", emoji: "🐸", tier: .gift,
                          pitchCents: -900, distortion: .none, distortionMix: 0,
                          eqBassGain: -4, eqBassFreq: 210,
                          noiseReduction: true, voiceBoost: false),
        NaiwaVoiceProfile(id: "loli", name: "萝莉音", emoji: "👧", tier: .unlockable,
                          pitchCents: 700, distortion: .none, distortionMix: 0,
                          eqBassGain: -3, eqBassFreq: 200,
                          noiseReduction: true, voiceBoost: true),
    ]

    static let defaultId = "naiwa"
    static func byId(_ id: String) -> NaiwaVoiceProfile? { all.first { $0.id == id } }
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

    /// Which user-facing voice is selected (奶蛙原声 / 萝莉音). Persisted so the
    /// choice survives relaunch. Set via `applyVoiceProfile`.
    @Published var selectedVoiceId: String = NaiwaVoiceProfile.defaultId {
        didSet { defaults.set(selectedVoiceId, forKey: Keys.selectedVoice) }
    }

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
        static let selectedVoice  = "naiwa_voice_selectedProfile"
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

        // Restore the user's selected voice. On a FRESH install (no saved
        // choice) apply the default profile so the shipped app starts on a
        // fully-defined奶蛙原声 rather than the bare code defaults. If a choice
        // was saved, trust the per-param values restored above (this also lets
        // the dev tune freely via the debug panel without being overwritten).
        if let savedVoice = defaults.string(forKey: Keys.selectedVoice) {
            selectedVoiceId = savedVoice
        } else if let profile = NaiwaVoiceProfile.byId(NaiwaVoiceProfile.defaultId) {
            applyVoiceProfile(profile)
        }
    }

    /// Switch the whole voice chain to a user-facing profile (奶蛙原声 / 萝莉音).
    /// Sets every param including the clarity toggles; each setter persists and
    /// pushes to its audio unit, so the change is live and survives relaunch.
    func applyVoiceProfile(_ profile: NaiwaVoiceProfile) {
        selectedVoiceId  = profile.id
        pitchCents       = profile.pitchCents
        distortionPreset = profile.distortion
        distortionMix    = profile.distortionMix
        eqBassGain       = profile.eqBassGain
        eqBassFreq       = profile.eqBassFreq
        noiseReduction   = profile.noiseReduction
        voiceBoost       = profile.voiceBoost
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

    /// The tap zone that STARTED the current user-triggered interaction. Tapping
    /// this same zone again rewinds & keeps playing (打枪/太极 feel, extended to
    /// all body interactions). Nil while idle or when奶蛙 self-triggered a filler,
    /// so those taps do nothing — only user-initiated motion is scrubbable.
    private var interactionRewindZone: TapZone?

    /// The equipped right-arm action, persisted. Tapping奶蛙's left arm plays it.
    /// "" = no action equipped → the right zone plays 挠头 (snappy default).
    @Published var equippedActionId: String = NaiwaAction.defaultId {
        didSet { UserDefaults.standard.set(equippedActionId, forKey: "naiwa_equippedAction") }
    }
    private var equippedClip: NaiwaClip {
        equippedActionId.isEmpty ? .head : (NaiwaAction.byId(equippedActionId)?.clip ?? .head)
    }

    /// Fired when the user starts a fresh interaction (zone tap / panel action).
    /// Drives the daily-task + lifetime interaction counters. Not fired on rewind.
    var onUserInteraction: (() -> Void)?
    /// Fired when奶蛙 actually starts speaking back a recording (real speech).
    var onSpeakStarted: (() -> Void)?

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
        interactionRewindZone = nil

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
                // Character-initiated → not user-scrubbable (taps stay inert).
                interactionRewindZone = nil
                switchTo(next)
            } else {
                switchTo(.idle)
            }
        case .fillerBelly, .fillerHead, .action, .laugh, .floating:
            state = .idle
            interactionRewindZone = nil
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
        // "连续点击倒退继播": if the user re-taps the SAME zone that started the
        // current interaction, rewind it ~0.5s and keep playing (打枪/太极 feel,
        // now on 大笑/摸肚子/浮起来/挠头 too). `interactionRewindZone` is only set
        // by a user tap below, so a character-initiated filler (belly/head from
        // the idle loop) has it nil and these taps are ignored.
        if let rewindZone = interactionRewindZone, zone == rewindZone, state.isUserInteraction {
            rewindAction()
            return
        }

        // Otherwise a fresh interaction only starts from a resting idle. Taps
        // during any ongoing clip (a running interaction, a self-filler, or
        // talk mode) do nothing.
        guard state == .idle else { return }

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
        // Remember which zone owns this interaction so re-taps scrub it.
        interactionRewindZone = zone
        onUserInteraction?()
    }

    /// Play a specific action's clip once (from the floating 动作 panel) WITHOUT
    /// changing what's equipped — a tap on a panel item. Interrupts a filler /
    /// laugh / floating / running action, but never talk mode. Re-tapping奶蛙's
    /// right arm during it rewinds like a normal equipped action.
    func playAction(_ actionId: String) {
        // Slice A: no unlock gating yet (comes in the panel-UI slice); just play.
        guard let action = NaiwaAction.byId(actionId), !state.isInTalkMode else { return }
        state = .action
        interactionRewindZone = .rightEdge
        switchTo(action.clip)
        onUserInteraction?()
    }

    /// Rewind the currently-playing action by `actionRewindStep`, clamped at
    /// frame 0, and keep playing. The `actionSeeking` guard drops taps that
    /// arrive while a seek is still resolving — that's what keeps rapid tapping
    /// from stacking seeks and stuttering. A small tolerance keeps the rewind
    /// snappy rather than frame-accurate (better feel for a "keep going" tap).
    private func rewindAction() {
        guard state.isUserInteraction, !actionSeeking, let p = players[currentClip] else { return }
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
                // Still mid-interaction? keep it rolling (seek can leave rate at 0).
                if self.state.isUserInteraction, let p = self.players[self.currentClip], p.rate == 0 {
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

        // Real speech is playing back → counts for the 变声 daily task.
        onSpeakStarted?()

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
    @ObservedObject var economy: Economy
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

                Section("经济（调试）") {
                    HStack {
                        Text("奶币 \(economy.coins)")
                            .font(.system(.body, design: .rounded))
                        Spacer()
                        Button("+50") { economy.debugGrant(50) }
                            .buttonStyle(.bordered)
                        Button("重置") { economy.debugReset() }
                            .buttonStyle(.bordered).tint(.red)
                    }
                }

                Section("加特林（调试）") {
                    HStack {
                        Text(economy.progress("gatling").discovered ? "状态：已获得" : "状态：未获得")
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("触发") { economy.debugTriggerGatling(); dismiss() }
                            .buttonStyle(.bordered)
                        Button("重置") { economy.debugResetGatling() }
                            .buttonStyle(.bordered).tint(.red)
                    }
                    Text("触发后会关闭本页，主屏出现「捡到加特林」弹窗")
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

// MARK: - Panel item badge & unlock dialog

/// Corner badge on a floating-panel item, reflecting its economy state.
enum ItemBadge: Equatable {
    case none
    case infinite          // ♾️ — gift or owned pack
    case uses(Int)         // ×N remaining (metered)
    case lockCoins(Int)    // 🔒 + 奶币 cost (免费 locked)
    case lockPack          // ¥ — founder pack
}

/// Modal shown when a locked / used-up / pack asset is tapped.
enum AssetDialog: Identifiable {
    case unlock(id: String, name: String, emoji: String)          // 免费 locked → pay coins (metered)
    case unlockPermanent(id: String, name: String, emoji: String) // 一次性买断 → pay once, forever
    case refill(id: String, name: String, emoji: String)          // uses 0 → buy more
    case founder(id: String, name: String, emoji: String)         // 打枪 pack → ¥
    case notEnough(needed: Int)

    var id: String {
        switch self {
        case .unlock(let i, _, _):          return "unlock-\(i)"
        case .unlockPermanent(let i, _, _): return "unlockPerm-\(i)"
        case .refill(let i, _, _):          return "refill-\(i)"
        case .founder(let i, _, _):         return "founder-\(i)"
        case .notEnough:                    return "notEnough"
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var naiwa = NaiwaPlayer()
    @StateObject private var economy = Economy()
    @StateObject private var store = StoreManager()
    @State private var assetDialog: AssetDialog?
    @State private var showHitZones = false
    @State private var showDebug = false
    @State private var showSettings = false
    @State private var showTasks = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var actionsPanelOpen = false
    @State private var voicesPanelOpen = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// Bumped periodically to make the 🎁 founder entry wiggle occasionally.
    @State private var giftBeat = 0
    /// Dev A/B clarity test: overlay a standalone 720P clip over the main scene.
    @State private var showTestVideo = false

    /// Hit-zones as explicit rectangles in VIDEO-normalized coords (0-1 within
    /// the 9:16 source frame), NOT screen coords. Taps are mapped back through
    /// the aspect-fill transform before testing, so a zone tracks奶蛙's body on
    /// any device aspect ratio. Tested in array order — FIRST hit wins — and a
    /// tap that lands in no rectangle does nothing (the empty/black areas).
    ///
    /// This table IS the tuning surface: each new scene gets its zones by
    /// tracing a reference layout image (colors here match that image — 黄挠头 /
    /// 绿摸肚子 / 紫打枪 / 红大笑 / 蓝浮起来) and pasting the measured rects here.
    private let zoneLayout: [(zone: TapZone, rect: CGRect)] = [
        (.head,        CGRect(x: 0.313, y: 0.135, width: 0.300, height: 0.198)),  // 黄 挠头
        (.leftEdge,    CGRect(x: 0.000, y: 0.213, width: 0.313, height: 0.385)),  // 绿 摸肚子
        (.rightEdge,   CGRect(x: 0.613, y: 0.213, width: 0.387, height: 0.385)),  // 紫 打枪
        (.upperMiddle, CGRect(x: 0.313, y: 0.333, width: 0.300, height: 0.265)),  // 红 大笑
        (.lowerMiddle, CGRect(x: 0.000, y: 0.598, width: 1.000, height: 0.402)),  // 蓝 浮起来
    ]

    /// All clips are 9:16 (720×1280 and 1792×3184 both ≈ 0.5625 w/h).
    private let videoAspect: CGFloat = 9.0 / 16.0

    var body: some View {
        GeometryReader { geo in
            // The video ignores safe area → it's laid out across the FULL
            // screen. Zone math must use that full rect (in the reader's local
            // coords, so the physical top-left is negative), otherwise zones get
            // squeezed into the safe area and drift down while 浮起来 loses its
            // lower half under the home indicator. Reduces to geo.size when the
            // safe-area insets are 0.
            let insets = geo.safeAreaInsets
            let videoBounds = CGRect(
                x: -insets.leading,
                y: -insets.top,
                width: geo.size.width + insets.leading + insets.trailing,
                height: geo.size.height + insets.top + insets.bottom
            )
            // Same full-screen video rect but with a ZERO origin — the coord
            // space of the safe-area-ignoring tap layer, whose local origin is
            // the physical screen top-left.
            let screenBounds = CGRect(origin: .zero, size: videoBounds.size)
            ZStack {
                Color.black.ignoresSafeArea()

                NaiwaSurface(view: naiwa.hostView)
                    .ignoresSafeArea()

                // A/B clarity test: overlay a standalone looping clip (奶蛙吃飞船,
                // 720P) on top of the main scene to eyeball it against the 2K
                // clips. Toggled from the top-left 🎬 button. Temporary dev tool.
                if showTestVideo {
                    LoopingVideoView(resource: "奶蛙吃飞船720P测试", subdirectory: "video")
                        .ignoresSafeArea()
                }

                // Full-screen tap layer (ignores safe area) so 浮起来 hit-tests
                // all the way to the physical bottom edge, including the home-
                // indicator strip. Below the chrome buttons so they keep tap
                // priority. Coordinates are physical (origin = screen top-left),
                // matching `screenBounds`.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                if let zone = zone(for: event.location, in: screenBounds) {
                                    naiwa.handleTap(zone)
                                }
                            }
                    )

                if showHitZones {
                    // Pin the overlay to the reader's size (top-left anchored) so
                    // the oversized (aspect-fill) rects can't inflate the parent
                    // ZStack — GeometryReader would anchor that top-left and shove
                    // the video + buttons right. NO .clipped(): 浮起来 is allowed to
                    // draw past the safe area down to the physical bottom edge.
                    debugOverlay(in: videoBounds)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }

                // Outside-tap catcher for the floating panels. Sits below the
                // chrome buttons so 动作/音色/录音 keep tap priority; any tap
                // elsewhere collapses the open panel.
                if actionsPanelOpen || voicesPanelOpen {
                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closePanels() }
                }

                // Top chrome: 奶币/任务入口 (left) · dev tools (center) · settings (right).
                VStack {
                    ZStack {
                        HStack {
                            coinPill        // tap → 任务中心
                                .padding(.leading, 14)
                            Spacer()
                            // User-facing settings.
                            circleEmojiButton("⚙️", size: 19) {
                                withAnimation(.easeInOut(duration: 0.15)) { showSettings = true }
                            }
                            .padding(.trailing, 14)
                        }
                        // Dev-only tools (gate/hide before shipping): debug panel
                        // + a 720P/2K clarity A/B toggle. Centered.
                        HStack(spacing: 10) {
                            circleIconButton("ladybug.fill", size: 17) { showDebug = true }
                            circleIconButton(showTestVideo ? "film.fill" : "film", size: 17) {
                                showTestVideo.toggle()
                            }
                        }
                    }
                    .padding(.top, 4)

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

                    // One row: 动作 (left) · record (center) · 音色 (right).
                    // Equal-width side buttons + equal Spacers keep the record
                    // button centered. Deliberately NO maxWidth:.infinity — that
                    // inflated the parent ZStack past the screen width, and since
                    // GeometryReader anchors content at its top-left, it shifted
                    // everything (video + buttons) right with the right edge cut off.
                    HStack {
                        bottomChromeButton("👻") { toggleActionsPanel() }
                        Spacer()
                        RecordButton(
                            isActive:  naiwa.isRecording,
                            isEnabled: naiwa.recordButtonEnabled,
                            onPress:   { closePanels(); naiwa.recordButtonPressed() },
                            onRelease: { naiwa.recordButtonReleased() }
                        )
                        Spacer()
                        bottomChromeButton("🎺") { toggleVoicesPanel() }
                    }
                    .padding(.horizontal, 26)
                }
                .padding(.bottom, 26)

                // Founder-pack entry — a compact tile just above the 动作 button.
                // Hidden once owned, and mutually exclusive with the 动作 panel.
                if !economy.progress("gun").infinite && !actionsPanelOpen {
                    founderTile
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 28)
                        .padding(.bottom, 122)
                        .transition(.scale(scale: 0.7, anchor: .bottomLeading).combined(with: .opacity))
                }

                // Floating panels sit ABOVE the chrome so their items are fully
                // tappable and can overlap the buttons. Anchored just above their
                // triggering corner button (Tom-Cat style).
                if actionsPanelOpen {
                    actionPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 18)
                        .padding(.bottom, 124)
                        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                }
                if voicesPanelOpen {
                    voicePanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 18)
                        .padding(.bottom, 124)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }

                // Transient toast — brief confirmation (e.g. equipping an action).
                // Top-center, above everything, never blocks touches.
                if let toast {
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 78)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        .allowsHitTesting(false)
                }

                // Settings page as a top-most overlay (not a sheet) so it simply
                // appears/fades instead of sliding up from the bottom.
                if showSettings {
                    NavigationStack {
                        SettingsView(store: store, onClose: {
                            withAnimation(.easeInOut(duration: 0.15)) { showSettings = false }
                        })
                    }
                    .transition(.opacity)
                }

                // Task center — same top-most instant overlay as settings.
                if showTasks {
                    NavigationStack {
                        TaskCenterView(economy: economy, onClose: {
                            withAnimation(.easeInOut(duration: 0.15)) { showTasks = false }
                        })
                    }
                    .transition(.opacity)
                }

                // Unlock / refill / founder dialog — modal, dimmed backdrop.
                if let dialog = assetDialog {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { dismissDialog() }
                    assetDialogCard(dialog)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                // 加特林 discovery celebration.
                if economy.justDiscoveredGatling {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    dialogShell(image: "加特林", emoji: "💥", glow: true, title: "太幸运了！",
                                message: "你的奶蛙偶然捡到了加特林！已解锁，送你 5 次",
                                primary: "收下", secondary: nil) {
                        withAnimation(.easeOut(duration: 0.2)) { economy.clearGatlingCelebration() }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: economy.justDiscoveredGatling)
        }
        .statusBarHidden()
        // Lock the whole UI to light mode so our black-on-white panels/pages
        // stay legible regardless of the user's system appearance.
        .preferredColorScheme(.light)
        .sheet(isPresented: $showDebug) {
            DebugPanel(voice: naiwa.voice, economy: economy, showHitZones: $showHitZones)
        }
        .onAppear {
            // Route player events into the daily-task counters (idempotent).
            naiwa.onUserInteraction = { economy.recordInteraction() }
            naiwa.onSpeakStarted = { economy.recordTalk() }
            economy.beginCompanionSession()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                economy.rolloverIfNeeded()
                economy.beginCompanionSession()
            case .inactive, .background:
                economy.endCompanionSession()
            @unknown default:
                break
            }
        }
        .task {
            // IAP: grant the founder pack from entitlements (purchase/restore/
            // cross-device), then correct a stale equipped action.
            store.onGunOwned = { economy.markPackOwned("gun") }
            await store.refreshEntitlements()
            validateEquip()
            // Periodic companion flush so the 5-minute task can complete while
            // the user simply keeps the app open watching奶蛙.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                economy.flushCompanion()
            }
        }
    }

    /// The equipped right-hand action must be ∞ (gift or owned pack). Reset a
    /// stale non-infinite value (e.g. an un-owned 打枪 from an old build) so it
    /// can't be played free from the right-hand zone.
    private func validateEquip() {
        if let a = NaiwaAction.byId(naiwa.equippedActionId), !isInfiniteAction(a) {
            naiwa.equippedActionId = NaiwaAction.defaultId
        }
    }

    // MARK: Floating panels (动作 / 音色)

    private var actionPanel: some View {
        // Hidden-tier assets (加特林) only appear once discovered.
        let items = NaiwaAction.catalog.filter { economy.isVisible($0.id, tier: $0.tier) }
        return floatingPanel(caption: "长按无限动作可设为右手装配动作", itemCount: items.count) {
            ForEach(items) { action in
                let isEquipped = action.id == naiwa.equippedActionId
                floatingItem(image: action.image, emoji: action.emoji,
                             selected: isEquipped, equipped: isEquipped,
                             badge: actionBadge(action),
                             onTap: { handleActionTap(action) },
                             onLongPress: { handleActionLongPress(action) })
            }
        }
    }

    private var voicePanel: some View {
        floatingPanel(caption: "点击切换音色", itemCount: NaiwaVoiceProfile.all.count) {
            ForEach(NaiwaVoiceProfile.all) { profile in
                floatingItem(image: nil, emoji: profile.emoji,   // voice images not ready → emoji
                             selected: profile.id == naiwa.voice.selectedVoiceId, equipped: false,
                             badge: voiceBadge(profile),
                             onTap: { handleVoiceTap(profile) })
            }
        }
    }

    // MARK: Panel tap handling (economy-gated)

    private func handleActionTap(_ a: NaiwaAction) {
        let p = economy.progress(a.id)
        switch a.tier {
        case .gift:
            playAndClose(a)
        case .free:
            if !p.unlocked {
                presentDialog(.unlock(id: a.id, name: a.name, emoji: a.emoji))
            } else if p.uses > 0 {
                economy.consumeUse(a.id); playAndClose(a)
            } else {
                presentDialog(.refill(id: a.id, name: a.name, emoji: a.emoji))
            }
        case .pack:
            if p.infinite {
                playAndClose(a)
            } else if p.previewsUsed < Economy.packPreviewLimit {
                economy.consumePreview(a.id)
                playAndClose(a)
                showToast("创始人礼包试玩 \(economy.progress(a.id).previewsUsed)/\(Economy.packPreviewLimit)")
            } else {
                presentDialog(.founder(id: a.id, name: a.name, emoji: a.emoji))
            }
        case .hidden:
            if p.uses > 0 {
                economy.consumeUse(a.id); playAndClose(a)
            } else {
                presentDialog(.refill(id: a.id, name: a.name, emoji: a.emoji))
            }
        case .unlockable:
            if p.unlocked { playAndClose(a) }
            else { presentDialog(.unlockPermanent(id: a.id, name: a.name, emoji: a.emoji)) }
        }
    }

    /// Long-press toggles the right-hand equip. Only ∞ actions are equippable;
    /// long-pressing the equipped one again unequips it (right zone → 挠头).
    private func handleActionLongPress(_ a: NaiwaAction) {
        if naiwa.equippedActionId == a.id {
            naiwa.equippedActionId = ""
            impact()
            closePanels()
            showToast("已取消装备 · 右手恢复默认")
            return
        }
        guard isInfiniteAction(a) else {
            impact()
            showToast("无限次的动作才能装备到右手")
            return
        }
        naiwa.equippedActionId = a.id
        impact()
        closePanels()
        showToast("\(a.name) 已装备到右手")
    }

    private func handleVoiceTap(_ v: NaiwaVoiceProfile) {
        // 一次性买断 voice still locked → permanent-unlock dialog. Otherwise select.
        if v.tier == .unlockable, !economy.progress(v.id).unlocked {
            presentDialog(.unlockPermanent(id: v.id, name: v.name, emoji: v.emoji))
        } else {
            naiwa.voice.applyVoiceProfile(v)
            impact()
            closePanels()
        }
    }

    private func playAndClose(_ a: NaiwaAction) {
        naiwa.playAction(a.id)
        closePanels()
    }

    private func isInfiniteAction(_ a: NaiwaAction) -> Bool {
        switch a.tier {
        case .gift:       return true
        case .pack:       return economy.progress(a.id).infinite
        case .unlockable: return economy.progress(a.id).infinite
        default:          return false
        }
    }

    private func actionBadge(_ a: NaiwaAction) -> ItemBadge {
        let p = economy.progress(a.id)
        switch a.tier {
        case .gift:       return .infinite
        case .free:       return p.unlocked ? (p.infinite ? .infinite : .uses(p.uses)) : .lockCoins(Economy.freeUnlockCost)
        case .pack:       return p.infinite ? .infinite : .lockPack
        case .hidden:     return .uses(p.uses)
        case .unlockable: return p.unlocked ? .infinite : .lockCoins(Economy.freeUnlockCost)
        }
    }

    private func voiceBadge(_ v: NaiwaVoiceProfile) -> ItemBadge {
        switch v.tier {
        case .unlockable: return economy.progress(v.id).unlocked ? .none : .lockCoins(Economy.freeUnlockCost)
        default:          return .none
        }
    }

    // MARK: Unlock dialog

    private func presentDialog(_ d: AssetDialog) {
        closePanels()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { assetDialog = d }
    }

    private func dismissDialog() {
        withAnimation(.easeOut(duration: 0.18)) { assetDialog = nil }
    }

    /// After a successful unlock/refill: select voices, but DON'T auto-play
    /// actions — let the user trigger them so奶蛙 feels alive, not like a media
    /// player. The granted uses stay intact for the user's own first tap.
    private func postUnlock(_ id: String) {
        if let v = NaiwaVoiceProfile.all.first(where: { $0.id == id }) {
            naiwa.voice.applyVoiceProfile(v)
        }
    }

    @ViewBuilder
    private func assetDialogCard(_ d: AssetDialog) -> some View {
        switch d {
        case .unlock(let id, let name, let emoji):
            dialogShell(image: NaiwaAction.byId(id)?.image, emoji: emoji, title: "解锁 \(name)",
                        message: "花 \(Economy.freeUnlockCost) 🪙 解锁，先送你 \(Economy.freeUnlockUses) 次",
                        primary: "花 \(Economy.freeUnlockCost) 🪙 解锁", secondary: "以后再说") {
                if economy.unlockFree(id) {
                    postUnlock(id); dismissDialog()
                    showToast("已解锁 \(name) · 送你 \(Economy.freeUnlockUses) 次")
                } else { withAnimation { assetDialog = .notEnough(needed: Economy.freeUnlockCost) } }
            }
        case .unlockPermanent(let id, let name, let emoji):
            dialogShell(image: NaiwaAction.byId(id)?.image, emoji: emoji, title: "解锁 \(name)",
                        message: "花 \(Economy.freeUnlockCost) 🪙 永久解锁 \(name)，之后随便用",
                        primary: "花 \(Economy.freeUnlockCost) 🪙 永久解锁", secondary: "以后再说") {
                if economy.unlockPermanent(id) {
                    postUnlock(id); dismissDialog()
                    showToast("已永久解锁 \(name)")
                } else { withAnimation { assetDialog = .notEnough(needed: Economy.freeUnlockCost) } }
            }
        case .refill(let id, let name, let emoji):
            dialogShell(image: NaiwaAction.byId(id)?.image, emoji: emoji, title: "\(name) 次数用完了",
                        message: "花 \(Economy.refillCost) 🪙 再来 \(Economy.refillUses) 次",
                        primary: "花 \(Economy.refillCost) 🪙 购买", secondary: "以后再说") {
                if economy.refill(id) {
                    postUnlock(id); dismissDialog()
                    showToast("已充值 · 再来 \(Economy.refillUses) 次")
                } else { withAnimation { assetDialog = .notEnough(needed: Economy.refillCost) } }
            }
        case .founder(_, let name, let emoji):
            let price = store.displayPrice(StoreManager.ProductID.gunPack)
            dialogShell(image: "打枪礼包", emoji: emoji, glow: true, title: "创始人礼包 · \(name)",
                        message: "解锁后永久无限次\(name)\(price.isEmpty ? "" : "（\(price)）")，并可长按装备到右手。",
                        primary: store.isBusy ? "购买中…" : (price.isEmpty ? "解锁" : "\(price) 解锁"),
                        secondary: "以后再说") {
                Task {
                    if await store.purchase(StoreManager.ProductID.gunPack) {
                        dismissDialog()
                        showToast("🔫 打枪 已解锁，永久无限!")
                    }
                }
            }
        case .notEnough(let needed):
            dialogShell(emoji: "🙈", title: "奶币不够啦",
                        message: "还差一点，先陪奶蛙多玩会儿赚奶币吧（需要 \(needed) 🪙）",
                        primary: "好的", secondary: nil) { dismissDialog() }
        }
    }

    private func dialogShell(image: String? = nil, emoji: String, glow: Bool = false,
                             title: String, message: String,
                             primary: String, secondary: String?,
                             onPrimary: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Group {
                if let image {
                    Image(image).resizable().scaledToFit().frame(width: 84, height: 84)
                } else {
                    Text(emoji).font(.system(size: 44))
                }
            }
            .background { if glow { giftGlow(124) } }
            Text(title).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
            Text(message).font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Button(action: onPrimary) {
                    Text(primary).font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color.black).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                if let secondary {
                    Button(action: dismissDialog) {
                        Text(secondary).font(.system(size: 15))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 286)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(red: 1.0, green: 0.99, blue: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
    }

    /// Rounded frosted card holding a row of items + a caption. Shared by both
    /// panels so 动作 and 音色 look identical.
    /// Frosted card with a 2-per-row grid of item tiles (scrolls past 3 rows) +
    /// a caption. `itemCount` sizes the scroll area so the card hugs its content.
    private func floatingPanel<Content: View>(caption: String, itemCount: Int,
                                              @ViewBuilder content: () -> Content) -> some View {
        let tile: CGFloat = 84, colGap: CGFloat = 14, rowGap: CGFloat = 16
        let columns = [GridItem(.fixed(tile), spacing: colGap), GridItem(.fixed(tile), spacing: colGap)]
        let rows = Int(ceil(Double(max(itemCount, 1)) / 2.0))
        let visibleRows = min(rows, 3)
        let gridHeight = CGFloat(visibleRows) * tile + CGFloat(max(0, visibleRows - 1)) * rowGap
        let pad: CGFloat = 8   // room so corner badges / rings aren't clipped by the scroll view
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: rowGap) { content() }
                    .padding(pad)
            }
            .frame(width: tile * 2 + colGap + pad * 2, height: gridHeight + pad * 2)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.black.opacity(0.4))
                .padding(.leading, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 1.0, green: 0.99, blue: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }

    /// One selectable item tile — just its Assets image (or emoji fallback), a
    /// state badge (top-right), and a 装配中 tag (top-left) when equipped. No
    /// text name. Tap fires `onTap`; long-press fires `onLongPress` (equip).
    private func floatingItem(image: String?, emoji: String,
                              selected: Bool, equipped: Bool,
                              badge: ItemBadge,
                              onTap: @escaping () -> Void,
                              onLongPress: (() -> Void)? = nil) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(selected ? Color.black.opacity(0.06) : Color.black.opacity(0.035))
            if let image {
                Image(image).resizable().scaledToFit().padding(9)
            } else {
                Text(emoji).font(.system(size: 40))
            }
        }
        .frame(width: 84, height: 84)
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(selected ? Color.black : Color.clear, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) { badgeView(badge) }
        .overlay(alignment: .bottom) {
            if equipped {
                Text("装配中")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black))
                    .padding(.bottom, 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.35) { onLongPress?() }
    }

    @ViewBuilder
    private func badgeView(_ badge: ItemBadge) -> some View {
        switch badge {
        case .none:
            EmptyView()
        case .infinite:
            badgeLabel("∞", bg: Color(red: 0.20, green: 0.72, blue: 0.40))
        case .uses(let n):
            badgeLabel("×\(n)", bg: n > 0 ? Color(red: 0.20, green: 0.52, blue: 0.95)
                                          : Color.gray.opacity(0.9))
        case .lockCoins(let c):
            badgeLabel("🔒\(c)", bg: Color(red: 0.95, green: 0.6, blue: 0.15))
        case .lockPack:
            badgeLabel("¥", bg: Color(red: 0.95, green: 0.35, blue: 0.55))
        }
    }

    private func badgeLabel(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
            .offset(x: 7, y: -7)
    }

    private func toggleActionsPanel() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            voicesPanelOpen = false
            actionsPanelOpen.toggle()
        }
    }

    private func toggleVoicesPanel() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            actionsPanelOpen = false
            voicesPanelOpen.toggle()
        }
    }

    private func closePanels() {
        guard actionsPanelOpen || voicesPanelOpen else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            actionsPanelOpen = false
            voicesPanelOpen = false
        }
    }

    private func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Show a transient toast for ~1.6s. Re-calling replaces the current one
    /// (the previous auto-dismiss task is cancelled).
    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.22)) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    /// 奶币 balance pill (top-left) — tap opens the 任务中心. A red dot signals
    /// tasks that are done but unclaimed.
    private var coinPill: some View {
        Button {
            economy.flushCompanion()
            withAnimation(.easeInOut(duration: 0.15)) { showTasks = true }
        } label: {
            HStack(spacing: 6) {
                coinIcon(22)
                Text("\(economy.coins)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
            }
            // No background — the black sky + earth should show through. A soft
            // shadow keeps it legible over both.
            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
            .overlay(alignment: .topTrailing) {
                if economy.claimableTaskCount > 0 {
                    Circle().fill(Color.red)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 0.5))
                        .offset(x: 4, y: -3)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .animation(.snappy, value: economy.coins)
    }

    /// Compact founder-pack entry above the 动作 button — a 🎁 that wiggles every
    /// few seconds to draw the eye.
    private var founderTile: some View {
        Button {
            presentDialog(.founder(id: "gun", name: "打枪", emoji: "🔫"))
        } label: {
            Image("打枪礼包")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .background(giftGlow(64))
                .phaseAnimator([0.0, -7, 5, -3, 0], trigger: giftBeat) { view, angle in
                    view.rotationEffect(.degrees(angle), anchor: .bottom)
                } animation: { _ in .easeInOut(duration: 0.13) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                giftBeat += 1
            }
        }
    }

    /// Soft warm bloom behind an icon. Single hue + wide falloff + blur reads as
    /// ambient light, not a solid blob.
    private func giftGlow(_ d: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.5).opacity(0.65), .clear]),
                center: .center, startRadius: 0, endRadius: d * 0.5))
            .frame(width: d, height: d)
            .blur(radius: d * 0.12)
            .allowsHitTesting(false)
    }

    /// The 奶币 coin image (transparent PNG in Assets), sized square.
    private func coinIcon(_ size: CGFloat) -> some View {
        Image("奶币").resizable().scaledToFit().frame(width: size, height: size)
    }

    /// Bottom-corner chrome button (动作 / 音色) — icon-only in a translucent
    /// circle (label dropped for a cleaner screen; the icon + opened panel are
    /// self-explanatory, and more category buttons are coming). Shared so every
    /// corner button stays visually identical.
    private func bottomChromeButton(_ emoji: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 27))
                .frame(width: 56, height: 56)
                .background(Color.black.opacity(0.7))
                .clipShape(Circle())
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

    /// Emoji variant of the top-chrome round button (keeps the main-screen icons
    /// consistently emoji).
    private func circleEmojiButton(_ emoji: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: size))
                .padding(8)
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

    private func zone(for point: CGPoint, in bounds: CGRect) -> TapZone? {
        // Test every rect in video space (so it tracks奶蛙 on any aspect ratio),
        // in priority order — head is listed first so it wins over the columns
        // it sits between. No rect contains the point → nil (empty area).
        let p = videoNormalizedPoint(for: point, in: bounds)
        return zoneLayout.first { $0.rect.contains(p) }?.zone
    }

    /// The video's displayed rect (in `bounds`' coordinate space) under
    /// `.resizeAspectFill` — it overflows the container; the offset is negative
    /// on the cropped axis. `bounds` is the FULL-screen video rect, which may
    /// start at a negative origin (it extends under the safe-area insets).
    private func displayedVideoRect(in bounds: CGRect) -> CGRect {
        let containerAspect = bounds.width / bounds.height
        var w = bounds.width, h = bounds.height
        if containerAspect > videoAspect {
            // Container wider than video → fill width, crop top/bottom.
            w = bounds.width
            h = bounds.width / videoAspect
        } else {
            // Container taller/narrower → fill height, crop sides.
            h = bounds.height
            w = bounds.height * videoAspect
        }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Screen point → video-normalized (0-1) coordinate, inverting aspect-fill.
    private func videoNormalizedPoint(for p: CGPoint, in bounds: CGRect) -> CGPoint {
        let r = displayedVideoRect(in: bounds)
        return CGPoint(x: (p.x - r.minX) / r.width,
                       y: (p.y - r.minY) / r.height)
    }

    /// Map a video-normalized rect forward into on-screen coords (aspect-fill),
    /// so the debug overlay lines up exactly with the hit-test rects.
    private func videoRectToScreen(_ r: CGRect, in bounds: CGRect) -> CGRect {
        let v = displayedVideoRect(in: bounds)
        return CGRect(x: v.minX + r.minX * v.width,
                      y: v.minY + r.minY * v.height,
                      width: r.width * v.width,
                      height: r.height * v.height)
    }

    /// Debug hit-zone overlay — draws every `zoneLayout` rect in its matching
    /// color/label so the tuning image and the live zones can be compared 1:1.
    /// The caller pins this to the reader's size + clips (the zone rects overflow
    /// the screen under aspect-fill and would otherwise inflate the layout).
    private func debugOverlay(in bounds: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(zoneLayout.enumerated()), id: \.offset) { _, entry in
                let r = videoRectToScreen(entry.rect, in: bounds)
                ZStack {
                    debugColor(for: entry.zone).opacity(0.30)
                    Text(debugLabel(for: entry.zone))
                        .foregroundColor(.white).font(.caption).bold()
                        .shadow(color: .black.opacity(0.6), radius: 3)
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private func debugColor(for zone: TapZone) -> Color {
        switch zone {
        case .head:        return .yellow
        case .leftEdge:    return .green
        case .rightEdge:   return .purple
        case .upperMiddle: return .red
        case .lowerMiddle: return .blue
        }
    }

    private func debugLabel(for zone: TapZone) -> String {
        switch zone {
        case .head:        return "挠头"
        case .leftEdge:    return "摸肚子"
        case .rightEdge:   return "打枪"
        case .upperMiddle: return "大笑"
        case .lowerMiddle: return "浮起来"
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

// MARK: - Standalone looping video (dev clarity test)

/// A self-contained aspect-fill video that loops seamlessly and auto-plays.
/// Independent of `NaiwaPlayer`'s state machine — used only for the 720P/2K
/// A/B comparison overlay. `AVPlayerLooper` gives gapless looping.
struct LoopingVideoView: UIViewRepresentable {
    let resource: String
    let subdirectory: String?

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(resource: resource, subdirectory: subdirectory)
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    final class PlayerUIView: UIView {
        private let queuePlayer = AVQueuePlayer()
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?

        init(resource: String, subdirectory: String?) {
            super.init(frame: .zero)
            backgroundColor = .black
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.player = queuePlayer
            layer.addSublayer(playerLayer)

            let url = Bundle.main.url(forResource: resource, withExtension: "mp4", subdirectory: subdirectory)
                ?? Bundle.main.url(forResource: resource, withExtension: "mp4")
            if let url {
                let item = AVPlayerItem(url: url)
                looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
                queuePlayer.isMuted = false
                queuePlayer.play()
            } else {
                print("⚠️ Missing test video: \(resource).mp4")
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
}

#Preview {
    ContentView()
}
