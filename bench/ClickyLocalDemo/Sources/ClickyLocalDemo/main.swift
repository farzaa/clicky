//
//  ClickyLocalDemo
//
//  A watch-only window app for Clicky's Local Mode. Mirrors the real app's
//  LocalChatProvider (same model: Llama-3.2-3B-Instruct-4bit, same cache dir,
//  same generation params, same local system prompt) and AppleSpeechSynthesis
//  client — but takes typed input instead of push-to-talk, so it needs none of
//  the mic / accessibility / screen-recording permissions the menu-bar app does.
//
//  It auto-runs a question on launch: model loads from disk, the answer streams
//  into the bubble with a "local · 0.6s · 57 tok/s" badge, and the reply is
//  spoken aloud. Wifi can be off the whole time.
//

import AppKit
import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import SwiftUI
import Tokenizers

// MARK: - Local system prompt (verbatim from the app's Local Mode)

let localSystemPrompt = """
you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk. you're running fully on their mac right now — no cloud, no screen access — so answer from what they said and what you remember of this conversation. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk.

rules:
- default to one or two sentences. be direct and dense. if the user asks you to go deeper, give a longer explanation.
- all lowercase, casual, warm. no emojis.
- write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
- don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
- you can't see the screen in local mode. if the user asks about something on their screen, say so plainly and ask them to read or describe it — or suggest flipping to a cloud model for screen questions.
- never say "simply" or "just".
- never output coordinate tags like [POINT:...] — you can't point at the screen in local mode.
"""

// MARK: - On-device engine (mirrors LocalChatProvider)

@MainActor
final class DemoLocalEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, loading(String), answering, spoken
    }
    @Published var phase: Phase = .idle
    @Published var answer: String = ""
    @Published var latencyBadge: String = ""
    @Published var isSpeaking = false

    private var modelContainer: ModelContainer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()

    init() {
        speechSynthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in self?.isSpeaking = false }
    }

    private func cacheDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent("Clicky/models/huggingface", isDirectory: true)
    }

    func ask(_ question: String) {
        Task { await run(question) }
    }

    private func run(_ question: String) async {
        do {
            if modelContainer == nil {
                phase = .loading("loading the on-device model…")
                MLX.Memory.cacheLimit = 32 * 1024 * 1024
                let hubClient = HubClient(cache: HubCache(cacheDirectory: try cacheDirectory()))
                modelContainer = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(hubClient),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: LLMRegistry.llama3_2_3B_4bit,
                    progressHandler: { progress in
                        let pct = Int(progress.fractionCompleted * 100)
                        Task { @MainActor [weak self] in self?.phase = .loading("downloading model… \(pct)%") }
                    }
                )
            }
            guard let modelContainer else { return }

            phase = .answering
            answer = ""
            latencyBadge = ""

            let input = try await modelContainer.prepare(input: UserInput(chat: [
                .system(localSystemPrompt),
                .user(question),
            ]))
            let requestStart = Date()
            var firstTokenAt: TimeInterval?
            var tokensPerSecond: Double?

            let stream = try await modelContainer.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 512, maxKVSize: 4096, temperature: 0.7))

            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    if firstTokenAt == nil { firstTokenAt = Date().timeIntervalSince(requestStart) }
                    answer += text
                case .info(let info):
                    tokensPerSecond = info.tokensPerSecond
                case .toolCall:
                    break
                }
            }

            answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstTokenAt {
                var badge = String(format: "local · %.1fs", firstTokenAt)
                if let tokensPerSecond { badge += String(format: " · %.0f tok/s", tokensPerSecond) }
                latencyBadge = badge
                FileHandle.standardError.write(Data("[demo] \(badge)\n".utf8))
            }
            FileHandle.standardError.write(Data("[demo] answer: \(answer)\n".utf8))
            FileHandle.standardError.write(Data("[demo] speaking…\n".utf8))

            speak(answer)
            phase = .spoken
        } catch {
            answer = "demo error: \(error.localizedDescription)"
            phase = .idle
        }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        utterance.voice = englishVoices.first(where: { $0.quality == .premium })
            ?? englishVoices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }
}

final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}

// MARK: - UI (Clicky dark aesthetic)

struct DemoView: View {
    @StateObject private var engine = DemoLocalEngine()
    @State private var question = "i'm making a boom bap beat in logic pro at 90 bpm — give me a kick, snare, and hi-hat pattern i can program on the step sequencer."

    private let surface = Color(red: 0.09, green: 0.10, blue: 0.095)
    private let cursorBlue = Color(red: 0.30, green: 0.55, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Clicky").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Text("Local Mode").font(.system(size: 11, weight: .medium)).foregroundColor(.gray)
                Spacer()
                // The picker, with Local lit (as it looks in the real panel)
                HStack(spacing: 0) {
                    pill("Sonnet", on: false); pill("Opus", on: false); pill("Local", on: true)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            }

            Text("your screen stays on your mac · works offline · $0")
                .font(.system(size: 11)).foregroundColor(.gray)

            HStack(spacing: 8) {
                TextField("ask anything…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13)).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                Button(action: { engine.ask(question) }) {
                    Text("Ask").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(cursorBlue))
                }.buttonStyle(.plain)
            }

            statusLine

            ScrollView {
                Text(engine.answer.isEmpty ? " " : engine.answer)
                    .font(.system(size: 14)).foregroundColor(.white).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            }
            .frame(maxHeight: .infinity)

            if !engine.latencyBadge.isEmpty {
                HStack(spacing: 6) {
                    Text(engine.latencyBadge)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(cursorBlue.opacity(0.25)))
                    if engine.isSpeaking {
                        Image(systemName: "speaker.wave.2.fill").foregroundColor(cursorBlue)
                        Text("speaking…").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 460)
        .background(surface)
        .onAppear {
            // Watch-only: kick off the demo question shortly after the window shows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { engine.ask(question) }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch engine.phase {
        case .idle: Text(" ").font(.system(size: 11))
        case .loading(let message): label(message, dim: true)
        case .answering: label("thinking on-device…", dim: true)
        case .spoken: label("answered locally — wifi never touched", dim: true)
        }
    }

    private func label(_ text: String, dim: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(dim ? .gray : .white)
    }

    private func pill(_ title: String, on: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .foregroundColor(on ? .white : .gray)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? cursorBlue.opacity(0.5) : .clear))
    }
}

// MARK: - AppKit bootstrap (window without a full .app bundle)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.title = "Clicky — Local Mode (demo)"
window.center()
window.contentView = NSHostingView(rootView: DemoView())
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
