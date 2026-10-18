import AVFoundation
import Foundation
import Speech

/// Cleans what the recogniser heard into something to search for.
enum VoiceQuery {
    static func clean(_ heard: String) -> String {
        var t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".?!,;:".contains(last) { t.removeLast() }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Voice search: listens through the microphone and turns speech into text with the system recogniser. It only runs when the person taps the
/// microphone, and only when the recogniser can work on this device, so the recording is never sent anywhere. Nothing is kept.
@MainActor
final class VoiceSearch: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    /// Set to a plain sentence when listening could not start; the caller shows it and clears it.
    @Published var problem: String?
    /// Called once with the cleaned words when speech ends.
    var onFinish: ((String) -> Void)?

    static let silenceSeconds = 1.6
    static let longestSeconds = 20.0

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var limitTimer: Timer?

    func toggle() {
        if listening { stop(commit: true) } else { Task { await start() } }
    }

    func start() async {
        guard !listening else { return }
        transcript = ""
        problem = nil
        guard await Self.speechAllowed() else { problem = "Allow Speech Recognition for Browser Setu in System Settings to use voice search."; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { problem = "Allow the microphone for Browser Setu in System Settings to use voice search."; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else { problem = "Voice search is not available for this language right now."; return }
        // Privacy first: no on-device model, no voice search. The audio is never sent to a server.
        guard recognizer.supportsOnDeviceRecognition else { problem = "Voice search needs on-device speech recognition for your language, which is not available. Nothing was recorded."; return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { problem = "The microphone could not be used."; self.request = nil; return }
        #endif
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { problem = "No microphone was found."; self.request = nil; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            problem = "The microphone could not be started."
            self.request = nil
            return
        }
        listening = true
        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.longestSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(commit: true) }
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.listening else { return }
                if let text { self.transcript = text; self.restartSilenceTimer() }
                if done || (error != nil && text == nil) { self.stop(commit: text != nil) }
            }
        }
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Self.silenceSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(commit: true) }
        }
    }

    /// Stops listening. With `commit`, what was heard is handed on.
    func stop(commit: Bool) {
        guard listening else { return }
        listening = false
        silenceTimer?.invalidate(); silenceTimer = nil
        limitTimer?.invalidate(); limitTimer = nil
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        let words = VoiceQuery.clean(transcript)
        if commit, !words.isEmpty { onFinish?(words) }
    }

    private static func speechAllowed() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}

import SwiftUI

/// The microphone in the search box. Red while listening; tapping again sends what was heard.
struct VoiceButton: View {
    @ObservedObject var voice: VoiceSearch
    var round = false

    var body: some View {
        Button { voice.toggle() } label: {
            Image(systemName: voice.listening ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(voice.listening ? Color.red : Color.secondary)
                .frame(width: round ? 56 : 28, height: round ? 56 : 28)
                .background { if round { Circle().fill(Color.primary.opacity(0.08)) } }
                .symbolEffect(.pulse, isActive: voice.listening)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(voice.listening ? "Stop and search" : "Search by voice (on this device)")
        .accessibilityLabel(voice.listening ? "Stop listening" : "Search by voice")
        .accessibilityIdentifier("voice-search")
        .motion(.easeOut(duration: 0.15), value: voice.listening)
    }
}
