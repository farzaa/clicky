//
//  main.swift
//  TakeoverGroundingSmokeTest
//
//  Loads Qwen2.5-VL-3B-Instruct-4bit (the takeover brain), feeds it a
//  screenshot path + a task, and prints the raw output and the parsed action.
//  Usage:
//    TakeoverGroundingSmokeTest <screenshot.png|jpg> "<task>"
//

import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

let systemPrompt = """
you control a mac by looking at one screenshot and choosing ONE action.
output EXACTLY ONE json object and NOTHING else — no prose, no markdown, no second action.
all coordinates are integer pixels in the screenshot, origin top-left (0,0 = top-left corner).

allowed actions (pick one):
{"action":"click","x":N,"y":N,"target_label":"short name of the thing","why":"one short clause"}
{"action":"type","text":"literal text","why":"..."}
{"action":"key","combo":"return | esc | cmd+s | ...","why":"..."}
{"action":"scroll","x":N,"y":N,"dir":"up|down|left|right","amount":1-5,"why":"..."}
{"action":"done","summary":"what you accomplished"}
{"action":"give_up","reason":"why you cannot continue"}

rules:
- one action per turn.
- click the CENTER of the target. if unsure, give_up instead of guessing.
- keep target_label and why to a few words.
"""

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: TakeoverGroundingSmokeTest <screenshot> \"<task>\"")
    exit(2)
}
let screenshotPath = arguments[1]
let task = arguments[2]

guard let screenshotImage = CIImage(contentsOf: URL(fileURLWithPath: screenshotPath)) else {
    print("could not read image at \(screenshotPath)")
    exit(2)
}
let widthInPixels = Int(screenshotImage.extent.width)
let heightInPixels = Int(screenshotImage.extent.height)

MLX.Memory.cacheLimit = 32 * 1024 * 1024

let modelCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Clicky/models/huggingface", isDirectory: true)
let hubClient = HubClient(cache: HubCache(cacheDirectory: modelCacheDirectory))

print("loading Qwen2.5-VL-3B-Instruct-4bit (downloads ~3 GB on first run)...")
let loadStart = Date()
let modelContainer = try await VLMModelFactory.shared.loadContainer(
    from: #hubDownloader(hubClient),
    using: #huggingFaceTokenizerLoader(),
    configuration: VLMRegistry.qwen2_5VL3BInstruct4Bit,
    progressHandler: { progress in
        print(String(format: "download: %3.0f%%", progress.fractionCompleted * 100))
    }
)
print(String(format: "model ready in %.1fs", Date().timeIntervalSince(loadStart)))

let userText = "TASK: \(task)\nThe screenshot below is \(widthInPixels)x\(heightInPixels) pixels. Choose one action."
let userInput = UserInput(chat: [
    .system(systemPrompt),
    .user(userText, images: [.ciImage(screenshotImage)]),
])

let requestStart = Date()
let languageModelInput = try await modelContainer.prepare(input: userInput)
let stream = try await modelContainer.generate(
    input: languageModelInput,
    parameters: GenerateParameters(maxTokens: 200, temperature: 0.2)
)

var rawOutput = ""
var firstTokenLatency: TimeInterval?
for await generation in stream {
    if case .chunk(let chunk) = generation {
        if firstTokenLatency == nil { firstTokenLatency = Date().timeIntervalSince(requestStart) }
        rawOutput += chunk
    }
}

print(String(format: "first token %.2fs | total %.1fs", firstTokenLatency ?? -1, Date().timeIntervalSince(requestStart)))
print("RAW: \(rawOutput)")
print("PARSEABLE-JSON: \(rawOutput.contains("{") && rawOutput.contains("}"))")
