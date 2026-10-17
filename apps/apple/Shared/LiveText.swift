import Foundation
import SwiftUI
@preconcurrency import Vision

/// Reads the words in a picture on this device with Apple's Vision framework. Nothing is sent anywhere.
enum LiveText {
    static func recognize(_ imageData: Data) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(data: imageData).perform([request]) } catch { continuation.resume(returning: "") }
            }
        }
    }
}

/// The words in what is on screen right now, including text inside pictures, video frames and canvases.
struct LiveTextView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(working ? "Reading…" : "Read Text on Screen") { Task { await read() } }.disabled(working).buttonStyle(.borderedProminent)
                if let text, !text.isEmpty { Button("Copy") { copyToPasteboard(text) }.buttonStyle(.bordered) }
            }
            .padding(.top, 12)
            if let text {
                if text.isEmpty { Text("No text was recognised in the visible part of the page.").foregroundStyle(.secondary).padding() }
                else { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) } }
            } else {
                Text("Finds words inside pictures and screenshots that you cannot select normally. Close this sheet’s view of the page first if something covers it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func read() async {
        working = true
        defer { working = false }
        guard let data = await model.active?.engine.screenshot(fullPage: false) else { text = ""; return }
        text = await LiveText.recognize(data)
    }
}
