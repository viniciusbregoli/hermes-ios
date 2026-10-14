import SwiftUI
import AVFoundation
import NaturalLanguage
import HermesKit

/// Reads a reply aloud with the gateway's configured voice, or the device's voice when the gateway has none.
@MainActor @Observable
final class Speaker: NSObject {
    enum Phase { case idle, loading, playing, paused }

    private(set) var state = Phase.idle
    /// Which voice is talking, for the player.
    private(set) var voice = ""

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var job: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ markdown: String, gateway: Gateway) {
        stop()
        let text = Speech.speakable(markdown)
        guard !text.isEmpty else { return }
        let useGateway = ReadAloudVoice(rawValue: UserDefaults.standard.string(forKey: ReadAloudVoice.key) ?? "") != .device
        state = .loading
        job = Task {
            var audio: (data: Data, provider: String?)?
            if useGateway { audio = try? await Speech.synthesize(text, via: gateway) }
            guard !Task.isCancelled else { return }
            activate()
            if let audio, let p = try? AVAudioPlayer(data: audio.data) {
                p.delegate = self
                player = p
                if let provider = audio.provider { UserDefaults.standard.set(provider, forKey: ReadAloudVoice.providerKey) }
                voice = "Hermes voice" + (audio.provider.map { " (\($0))" } ?? "")
                p.play()
            } else {
                let u = AVSpeechUtterance(string: text)
                // The reply may not be in the device's language; pick a voice for the text's own.
                if let lang = NLLanguageRecognizer.dominantLanguage(for: text) { u.voice = AVSpeechSynthesisVoice(language: lang.rawValue) }
                utterance = u
                voice = "On-device voice"
                synth.speak(u)
            }
            state = .playing
        }
    }

    func togglePause() {
        switch state {
        case .playing:
            if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
            state = .paused
        case .paused:
            if let player { player.play() } else { synth.continueSpeaking() }
            state = .playing
        default: break
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        player?.stop()
        player = nil
        utterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        guard state != .idle else { return }
        state = .idle
        deactivate()
    }

    // Playback plays through the silent switch, like any audio the user asked for; only while speaking,
    // so the rest of the app keeps the default (silenced) behavior.
    private func activate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        #endif
    }
}

extension Speaker: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === p { self.stop() } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if self.utterance === u { self.stop() } }
    }
}

/// Floating player while a reply is read aloud: pause or resume, and stop.
struct SpeechBar: View {
    let speaker: Speaker

    var body: some View {
        if speaker.state != .idle {
            HStack(spacing: 12) {
                if speaker.state == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "waveform").symbolEffect(.variableColor, isActive: speaker.state == .playing)
                        .foregroundStyle(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(speaker.state == .loading ? "Preparing audio…" : "Reading aloud").font(.subheadline.weight(.medium))
                    if !speaker.voice.isEmpty { Text(speaker.voice).font(.caption2).foregroundStyle(Theme.muted) }
                }
                Spacer(minLength: 4)
                Button { speaker.togglePause() } label: {
                    Image(systemName: speaker.state == .paused ? "play.fill" : "pause.fill").frame(width: 30, height: 30)
                }
                .disabled(speaker.state == .loading)
                .accessibilityLabel(speaker.state == .paused ? "Resume" : "Pause")
                Button { speaker.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 30, height: 30)
                }
                .accessibilityLabel("Stop reading")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.sidebar, in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
            .frame(maxWidth: 360)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Which voice reads replies aloud. The gateway's provider may bill per character, so the user can opt out of it.
enum ReadAloudVoice: String {
    case hermes, device

    static let key = "readAloudVoice"
    /// The gateway's TTS provider as its last reply named it, for the settings label.
    static let providerKey = "readAloudProvider"
}

/// Settings: which voice reads replies aloud.
struct ReadAloudSettingsSection: View {
    @AppStorage(ReadAloudVoice.key) private var voice = ReadAloudVoice.hermes.rawValue
    @AppStorage(ReadAloudVoice.providerKey) private var provider = ""

    var body: some View {
        Section {
            Picker("Read aloud voice", selection: $voice) {
                Text("Hermes voice" + (provider.isEmpty ? "" : " (\(provider))")).tag(ReadAloudVoice.hermes.rawValue)
                Text("On-device").tag(ReadAloudVoice.device.rawValue)
            }
        } footer: {
            Text("The Hermes voice uses the gateway's text-to-speech provider, which may count against its quota. On-device is free and works offline.")
        }
        .listRowBackground(Theme.sidebar)
    }
}
