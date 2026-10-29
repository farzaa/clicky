// SupertonicEngine.swift
// Vendored from supertone-inc/supertonic (swift/Sources/Helper.swift)
// https://github.com/supertone-inc/supertonic — MIT License
//
// Renames: Config→SupertonicConfig, Style→SupertonicStyle, TextToSpeech→SupertonicTTS,
//          UnicodeProcessor→SupertonicUnicodeProcessor, VoiceStyleData→SupertonicVoiceStyleData
// Removed: writeWavFile, timer, sanitizeFilename (CLI-only helpers)
// Added: SupertonicTTS.synthesize() convenience that encapsulates style loading

import Foundation
import OnnxRuntimeBindings

// MARK: - Available Languages

private let SUPERTONIC_LANGS = ["en", "ko", "es", "pt", "fr"]

private func isValidSupertonicLang(_ lang: String) -> Bool {
    SUPERTONIC_LANGS.contains(lang)
}

// MARK: - Configuration Structures

struct SupertonicConfig: Codable {
    struct AEConfig: Codable {
        let sample_rate: Int
        let base_chunk_size: Int
    }

    struct TTLConfig: Codable {
        let chunk_compress_factor: Int
        let latent_dim: Int
    }

    let ae: AEConfig
    let ttl: TTLConfig
}

// MARK: - Voice Style Data Structure

private struct SupertonicVoiceStyleData: Codable {
    struct StyleComponent: Codable {
        let data: [[[Float]]]
        let dims: [Int]
        let type: String
    }

    let style_ttl: StyleComponent
    let style_dp: StyleComponent
}

// MARK: - Unicode Text Processor

class SupertonicUnicodeProcessor {
    let indexer: [Int64]

    init(unicodeIndexerPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: unicodeIndexerPath))
        self.indexer = try JSONDecoder().decode([Int64].self, from: data)
    }

    func call(_ textList: [String], _ langList: [String]) -> (textIds: [[Int64]], textMask: [[[Float]]]) {
        var processedTexts = [String]()
        for (i, text) in textList.enumerated() {
            processedTexts.append(supertonicPreprocessText(text, lang: langList[i]))
        }

        var textIdsLengths = [Int]()
        for text in processedTexts {
            textIdsLengths.append(text.unicodeScalars.count)
        }

        let maxLen = textIdsLengths.max() ?? 0

        var textIds = [[Int64]]()
        for text in processedTexts {
            var row = Array(repeating: Int64(0), count: maxLen)
            let unicodeValues = Array(text.unicodeScalars.map { Int($0.value) })
            for (j, val) in unicodeValues.enumerated() {
                if val < indexer.count {
                    row[j] = indexer[val]
                } else {
                    row[j] = -1
                }
            }
            textIds.append(row)
        }

        let textMask = supertonicGetTextMask(textIdsLengths)
        return (textIds, textMask)
    }
}

// MARK: - Text Preprocessing

private func supertonicPreprocessText(_ text: String, lang: String) -> String {
    var text = text.decomposedStringWithCompatibilityMapping

    // Remove emojis
    text = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        return !((value >= 0x1F600 && value <= 0x1F64F) ||
                 (value >= 0x1F300 && value <= 0x1F5FF) ||
                 (value >= 0x1F680 && value <= 0x1F6FF) ||
                 (value >= 0x1F700 && value <= 0x1F77F) ||
                 (value >= 0x1F780 && value <= 0x1F7FF) ||
                 (value >= 0x1F800 && value <= 0x1F8FF) ||
                 (value >= 0x1F900 && value <= 0x1F9FF) ||
                 (value >= 0x1FA00 && value <= 0x1FA6F) ||
                 (value >= 0x1FA70 && value <= 0x1FAFF) ||
                 (value >= 0x2600 && value <= 0x26FF) ||
                 (value >= 0x2700 && value <= 0x27BF) ||
                 (value >= 0x1F1E6 && value <= 0x1F1FF))
    }.map { String($0) }.joined()

    let replacements: [String: String] = [
        "\u{2013}": "-", "\u{2011}": "-", "\u{2014}": "-", "_": " ",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{2018}": "'", "\u{2019}": "'",
        "\u{00B4}": "'", "`": "'",
        "[": " ", "]": " ", "|": " ", "/": " ", "#": " ",
        "\u{2192}": " ", "\u{2190}": " ",
    ]

    for (old, new) in replacements {
        text = text.replacingOccurrences(of: old, with: new)
    }

    let specialSymbols = ["♥", "☆", "♡", "©", "\\"]
    for symbol in specialSymbols {
        text = text.replacingOccurrences(of: symbol, with: "")
    }

    let exprReplacements: [String: String] = [
        "@": " at ", "e.g.,": "for example, ", "i.e.,": "that is, ",
    ]

    for (old, new) in exprReplacements {
        text = text.replacingOccurrences(of: old, with: new)
    }

    text = text.replacingOccurrences(of: " ,", with: ",")
    text = text.replacingOccurrences(of: " .", with: ".")
    text = text.replacingOccurrences(of: " !", with: "!")
    text = text.replacingOccurrences(of: " ?", with: "?")
    text = text.replacingOccurrences(of: " ;", with: ";")
    text = text.replacingOccurrences(of: " :", with: ":")
    text = text.replacingOccurrences(of: " '", with: "'")

    while text.contains("\"\"") { text = text.replacingOccurrences(of: "\"\"", with: "\"") }
    while text.contains("''") { text = text.replacingOccurrences(of: "''", with: "'") }
    while text.contains("``") { text = text.replacingOccurrences(of: "``", with: "`") }

    let whitespacePattern = try! NSRegularExpression(pattern: "\\s+")
    let wsRange = NSRange(text.startIndex..., in: text)
    text = whitespacePattern.stringByReplacingMatches(in: text, range: wsRange, withTemplate: " ")

    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if !text.isEmpty {
        let punctPattern = try! NSRegularExpression(
            pattern: "[.!?;:,'\"\u{201C}\u{201D}\u{2018}\u{2019})\\]\\}\u{2026}]$")
        let punctRange = NSRange(text.startIndex..., in: text)
        if punctPattern.firstMatch(in: text, range: punctRange) == nil {
            text += "."
        }
    }

    guard isValidSupertonicLang(lang) else {
        fatalError("Invalid language: \(lang). Available: \(SUPERTONIC_LANGS.joined(separator: ", "))")
    }

    text = "<\(lang)>\(text)</\(lang)>"
    return text
}

// MARK: - Mask Utilities

private func supertonicLengthToMask(_ lengths: [Int], maxLen: Int? = nil) -> [[[Float]]] {
    let actualMaxLen = maxLen ?? (lengths.max() ?? 0)
    var mask = [[[Float]]]()

    for len in lengths {
        var row = Array(repeating: Float(0.0), count: actualMaxLen)
        for j in 0..<min(len, actualMaxLen) { row[j] = 1.0 }
        mask.append([row])
    }
    return mask
}

private func supertonicGetTextMask(_ textIdsLengths: [Int]) -> [[[Float]]] {
    let maxLen = textIdsLengths.max() ?? 0
    return supertonicLengthToMask(textIdsLengths, maxLen: maxLen)
}

private func supertonicSampleNoisyLatent(
    duration: [Float], sampleRate: Int, baseChunkSize: Int,
    chunkCompress: Int, latentDim: Int
) -> (noisyLatent: [[[Float]]], latentMask: [[[Float]]]) {
    let bsz = duration.count
    let maxDur = duration.max() ?? 0.0
    let wavLenMax = Int(maxDur * Float(sampleRate))

    var wavLengths = [Int]()
    for d in duration { wavLengths.append(Int(d * Float(sampleRate))) }

    let chunkSize = baseChunkSize * chunkCompress
    let latentLen = (wavLenMax + chunkSize - 1) / chunkSize
    let latentDimVal = latentDim * chunkCompress

    var noisyLatent = [[[Float]]]()
    for _ in 0..<bsz {
        var batch = [[Float]]()
        for _ in 0..<latentDimVal {
            var row = [Float]()
            for _ in 0..<latentLen {
                let u1 = Float.random(in: 0.0001...1.0)
                let u2 = Float.random(in: 0.0...1.0)
                let val = sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
                row.append(val)
            }
            batch.append(row)
        }
        noisyLatent.append(batch)
    }

    var latentLengths = [Int]()
    for len in wavLengths { latentLengths.append((len + chunkSize - 1) / chunkSize) }

    let latentMask = supertonicLengthToMask(latentLengths, maxLen: latentLen)

    for b in 0..<bsz {
        for d in 0..<latentDimVal {
            for t in 0..<latentLen {
                noisyLatent[b][d][t] *= latentMask[b][0][t]
            }
        }
    }

    return (noisyLatent, latentMask)
}

// MARK: - Text Chunking

private let SUPERTONIC_MAX_CHUNK_LENGTH = 300

private let SUPERTONIC_ABBREVIATIONS = [
    "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.",
    "St.", "Ave.", "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.",
    "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
]

private func supertonicChunkText(_ text: String, maxLen: Int = 0) -> [String] {
    let actualMaxLen = maxLen > 0 ? maxLen : SUPERTONIC_MAX_CHUNK_LENGTH
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedText.isEmpty { return [""] }

    let paraPattern = try! NSRegularExpression(pattern: "\\n\\s*\\n")
    let paraRange = NSRange(trimmedText.startIndex..., in: trimmedText)

    var paragraphs = [String]()
    var lastEnd = trimmedText.startIndex

    paraPattern.enumerateMatches(in: trimmedText, range: paraRange) { match, _, _ in
        if let match = match, let range = Range(match.range, in: trimmedText) {
            paragraphs.append(String(trimmedText[lastEnd..<range.lowerBound]))
            lastEnd = range.upperBound
        }
    }

    if lastEnd < trimmedText.endIndex { paragraphs.append(String(trimmedText[lastEnd...])) }
    if paragraphs.isEmpty { paragraphs = [trimmedText] }

    var chunks = [String]()

    for para in paragraphs {
        let trimmedPara = para.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPara.isEmpty { continue }

        if trimmedPara.count <= actualMaxLen { chunks.append(trimmedPara); continue }

        let sentences = supertonicSplitSentences(trimmedPara)
        var current = ""
        var currentLen = 0

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSentence.isEmpty { continue }

            let sentenceLen = trimmedSentence.count

            if sentenceLen > actualMaxLen {
                if !current.isEmpty {
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""; currentLen = 0
                }

                let parts = trimmedSentence.components(separatedBy: ",")
                for part in parts {
                    let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedPart.isEmpty { continue }

                    let partLen = trimmedPart.count

                    if partLen > actualMaxLen {
                        let words = trimmedPart.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        var wordChunk = ""; var wordChunkLen = 0

                        for word in words {
                            let wordLen = word.count
                            if wordChunkLen + wordLen + 1 > actualMaxLen && !wordChunk.isEmpty {
                                chunks.append(wordChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                                wordChunk = ""; wordChunkLen = 0
                            }
                            if !wordChunk.isEmpty { wordChunk += " "; wordChunkLen += 1 }
                            wordChunk += word; wordChunkLen += wordLen
                        }

                        if !wordChunk.isEmpty {
                            chunks.append(wordChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } else {
                        if currentLen + partLen + 1 > actualMaxLen && !current.isEmpty {
                            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                            current = ""; currentLen = 0
                        }
                        if !current.isEmpty { current += ", "; currentLen += 2 }
                        current += trimmedPart; currentLen += partLen
                    }
                }
                continue
            }

            if currentLen + sentenceLen + 1 > actualMaxLen && !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""; currentLen = 0
            }

            if !current.isEmpty { current += " "; currentLen += 1 }
            current += trimmedSentence; currentLen += sentenceLen
        }

        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    return chunks.isEmpty ? [""] : chunks
}

private func supertonicSplitSentences(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "([.!?])\\s+")
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)

    if matches.isEmpty { return [text] }

    var sentences = [String]()
    var lastEnd = text.startIndex

    for match in matches {
        guard let matchRange = Range(match.range, in: text) else { continue }

        let puncRange = Range(NSRange(location: match.range.location, length: 1), in: text)!
        let punc = String(text[puncRange])

        let combined = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces) + punc

        var isAbbrev = false
        for abbrev in SUPERTONIC_ABBREVIATIONS {
            if combined.hasSuffix(abbrev) { isAbbrev = true; break }
        }

        if !isAbbrev {
            sentences.append(String(text[lastEnd..<matchRange.upperBound]))
            lastEnd = matchRange.upperBound
        }
    }

    if lastEnd < text.endIndex { sentences.append(String(text[lastEnd...])) }
    return sentences.isEmpty ? [text] : sentences
}

// MARK: - ONNX Runtime Integration

struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue
}

class SupertonicTTS {
    let env: ORTEnv
    let cfgs: SupertonicConfig

    private let textProcessor: SupertonicUnicodeProcessor
    private let dpOrt: ORTSession
    private let textEncOrt: ORTSession
    private let vectorEstOrt: ORTSession
    private let vocoderOrt: ORTSession

    let sampleRate: Int

    init(env: ORTEnv, cfgs: SupertonicConfig, textProcessor: SupertonicUnicodeProcessor,
         dpOrt: ORTSession, textEncOrt: ORTSession,
         vectorEstOrt: ORTSession, vocoderOrt: ORTSession) {
        self.env = env
        self.cfgs = cfgs
        self.textProcessor = textProcessor
        self.dpOrt = dpOrt
        self.textEncOrt = textEncOrt
        self.vectorEstOrt = vectorEstOrt
        self.vocoderOrt = vocoderOrt
        self.sampleRate = cfgs.ae.sample_rate
    }

    // MARK: Convenience — synthesize with voice style path

    func synthesize(text: String, lang: String, voiceStylePath: String,
                    totalStep: Int = 5, speed: Float = 1.05) throws -> (wav: [Float], duration: Float) {
        let style = try supertonicLoadVoiceStyle([voiceStylePath])
        return try call(text, lang, style, totalStep, speed: speed)
    }

    // MARK: Core inference

    private func _infer(_ textList: [String], _ langList: [String], _ style: SupertonicStyle,
                        _ totalStep: Int, speed: Float = 1.05) throws -> (wav: [Float], duration: [Float]) {
        let bsz = textList.count

        let (textIds, textMask) = textProcessor.call(textList, langList)

        let textIdsFlat = textIds.flatMap { $0 }
        let textIdsShape: [NSNumber] = [NSNumber(value: bsz), NSNumber(value: textIds[0].count)]

        let textIdsValue = try ORTValue(
            tensorData: NSMutableData(bytes: textIdsFlat, length: textIdsFlat.count * MemoryLayout<Int64>.size),
            elementType: .int64, shape: textIdsShape)

        let textMaskFlat = textMask.flatMap { $0.flatMap { $0 } }
        let textMaskShape: [NSNumber] = [NSNumber(value: bsz), 1, NSNumber(value: textMask[0][0].count)]

        let textMaskValue = try ORTValue(
            tensorData: NSMutableData(bytes: textMaskFlat, length: textMaskFlat.count * MemoryLayout<Float>.size),
            elementType: .float, shape: textMaskShape)

        // Duration prediction
        let dpOutputs = try dpOrt.run(
            withInputs: ["text_ids": textIdsValue, "style_dp": style.dp, "text_mask": textMaskValue],
            outputNames: ["duration"], runOptions: nil)

        let durationData = try dpOutputs["duration"]!.tensorData() as Data
        var duration = durationData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in 0..<duration.count { duration[i] /= speed }

        // Text encoding
        let textEncOutputs = try textEncOrt.run(
            withInputs: ["text_ids": textIdsValue, "style_ttl": style.ttl, "text_mask": textMaskValue],
            outputNames: ["text_emb"], runOptions: nil)

        let textEmbValue = textEncOutputs["text_emb"]!

        // Sample noisy latent
        var (xt, latentMask) = supertonicSampleNoisyLatent(
            duration: duration, sampleRate: sampleRate,
            baseChunkSize: cfgs.ae.base_chunk_size,
            chunkCompress: cfgs.ttl.chunk_compress_factor,
            latentDim: cfgs.ttl.latent_dim)

        let totalStepArray = Array(repeating: Float(totalStep), count: bsz)
        let totalStepValue = try ORTValue(
            tensorData: NSMutableData(bytes: totalStepArray, length: totalStepArray.count * MemoryLayout<Float>.size),
            elementType: .float, shape: [NSNumber(value: bsz)])

        // Denoising loop
        for step in 0..<totalStep {
            let currentStepArray = Array(repeating: Float(step), count: bsz)
            let currentStepValue = try ORTValue(
                tensorData: NSMutableData(bytes: currentStepArray, length: currentStepArray.count * MemoryLayout<Float>.size),
                elementType: .float, shape: [NSNumber(value: bsz)])

            let xtFlat = xt.flatMap { $0.flatMap { $0 } }
            let xtShape: [NSNumber] = [NSNumber(value: bsz), NSNumber(value: xt[0].count), NSNumber(value: xt[0][0].count)]

            let xtValue = try ORTValue(
                tensorData: NSMutableData(bytes: xtFlat, length: xtFlat.count * MemoryLayout<Float>.size),
                elementType: .float, shape: xtShape)

            let latentMaskFlat = latentMask.flatMap { $0.flatMap { $0 } }
            let latentMaskShape: [NSNumber] = [NSNumber(value: bsz), 1, NSNumber(value: latentMask[0][0].count)]

            let latentMaskValue = try ORTValue(
                tensorData: NSMutableData(bytes: latentMaskFlat, length: latentMaskFlat.count * MemoryLayout<Float>.size),
                elementType: .float, shape: latentMaskShape)

            let vectorEstOutputs = try vectorEstOrt.run(withInputs: [
                "noisy_latent": xtValue, "text_emb": textEmbValue, "style_ttl": style.ttl,
                "latent_mask": latentMaskValue, "text_mask": textMaskValue,
                "current_step": currentStepValue, "total_step": totalStepValue,
            ], outputNames: ["denoised_latent"], runOptions: nil)

            let denoisedData = try vectorEstOutputs["denoised_latent"]!.tensorData() as Data
            let denoisedFlat = denoisedData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            let latentDimVal = xt[0].count
            let latentLen = xt[0][0].count

            xt = []

            var idx = 0
            for _ in 0..<bsz {
                var batch = [[Float]]()
                for _ in 0..<latentDimVal {
                    var row = [Float]()
                    for _ in 0..<latentLen { row.append(denoisedFlat[idx]); idx += 1 }
                    batch.append(row)
                }
                xt.append(batch)
            }
        }

        // Vocoder
        let finalXtFlat = xt.flatMap { $0.flatMap { $0 } }
        let finalXtShape: [NSNumber] = [NSNumber(value: bsz), NSNumber(value: xt[0].count), NSNumber(value: xt[0][0].count)]

        let finalXtValue = try ORTValue(
            tensorData: NSMutableData(bytes: finalXtFlat, length: finalXtFlat.count * MemoryLayout<Float>.size),
            elementType: .float, shape: finalXtShape)

        let vocoderOutputs = try vocoderOrt.run(
            withInputs: ["latent": finalXtValue], outputNames: ["wav_tts"], runOptions: nil)

        let wavData = try vocoderOutputs["wav_tts"]!.tensorData() as Data
        let wav = wavData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        return (wav, duration)
    }

    func call(_ text: String, _ lang: String, _ style: SupertonicStyle, _ totalStep: Int,
              speed: Float = 1.05, silenceDuration: Float = 0.3) throws -> (wav: [Float], duration: Float) {
        let maxLen = lang == "ko" ? 120 : 300
        let chunks = supertonicChunkText(text, maxLen: maxLen)
        let langList = Array(repeating: lang, count: chunks.count)

        var wavCat = [Float]()
        var durCat: Float = 0.0

        for (i, chunk) in chunks.enumerated() {
            let result = try _infer([chunk], [langList[i]], style, totalStep, speed: speed)
            let dur = result.duration[0]
            let wavLen = Int(Float(sampleRate) * dur)
            let wavChunk = Array(result.wav.prefix(wavLen))

            if i == 0 {
                wavCat = wavChunk
                durCat = dur
            } else {
                let silenceLen = Int(silenceDuration * Float(sampleRate))
                wavCat.append(contentsOf: [Float](repeating: 0.0, count: silenceLen))
                wavCat.append(contentsOf: wavChunk)
                durCat += silenceDuration + dur
            }
        }

        return (wavCat, durCat)
    }
}

// MARK: - Component Loading Functions

func supertonicLoadVoiceStyle(_ voiceStylePaths: [String]) throws -> SupertonicStyle {
    let bsz = voiceStylePaths.count

    let firstData = try Data(contentsOf: URL(fileURLWithPath: voiceStylePaths[0]))
    let firstStyle = try JSONDecoder().decode(SupertonicVoiceStyleData.self, from: firstData)

    let ttlDims = firstStyle.style_ttl.dims
    let dpDims = firstStyle.style_dp.dims

    let ttlDim1 = ttlDims[1], ttlDim2 = ttlDims[2]
    let dpDim1 = dpDims[1], dpDim2 = dpDims[2]

    var ttlFlat = [Float](repeating: 0.0, count: bsz * ttlDim1 * ttlDim2)
    var dpFlat = [Float](repeating: 0.0, count: bsz * dpDim1 * dpDim2)

    for (i, path) in voiceStylePaths.enumerated() {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let voiceStyle = try JSONDecoder().decode(SupertonicVoiceStyleData.self, from: data)

        var idx = 0
        let ttlOffset = i * ttlDim1 * ttlDim2
        for batch in voiceStyle.style_ttl.data {
            for row in batch { for val in row { ttlFlat[ttlOffset + idx] = val; idx += 1 } }
        }

        idx = 0
        let dpOffset = i * dpDim1 * dpDim2
        for batch in voiceStyle.style_dp.data {
            for row in batch { for val in row { dpFlat[dpOffset + idx] = val; idx += 1 } }
        }
    }

    let ttlShape: [NSNumber] = [NSNumber(value: bsz), NSNumber(value: ttlDim1), NSNumber(value: ttlDim2)]
    let dpShape: [NSNumber] = [NSNumber(value: bsz), NSNumber(value: dpDim1), NSNumber(value: dpDim2)]

    let ttlValue = try ORTValue(
        tensorData: NSMutableData(bytes: &ttlFlat, length: ttlFlat.count * MemoryLayout<Float>.size),
        elementType: .float, shape: ttlShape)

    let dpValue = try ORTValue(
        tensorData: NSMutableData(bytes: &dpFlat, length: dpFlat.count * MemoryLayout<Float>.size),
        elementType: .float, shape: dpShape)

    return SupertonicStyle(ttl: ttlValue, dp: dpValue)
}

func supertonicLoadEngine(onnxDir: String) throws -> SupertonicTTS {
    let env = try ORTEnv(loggingLevel: .warning)

    let cfgPath = "\(onnxDir)/tts.json"
    let data = try Data(contentsOf: URL(fileURLWithPath: cfgPath))
    let cfgs = try JSONDecoder().decode(SupertonicConfig.self, from: data)

    let sessionOptions = try ORTSessionOptions()

    let dpOrt = try ORTSession(env: env, modelPath: "\(onnxDir)/duration_predictor.onnx", sessionOptions: sessionOptions)
    let textEncOrt = try ORTSession(env: env, modelPath: "\(onnxDir)/text_encoder.onnx", sessionOptions: sessionOptions)
    let vectorEstOrt = try ORTSession(env: env, modelPath: "\(onnxDir)/vector_estimator.onnx", sessionOptions: sessionOptions)
    let vocoderOrt = try ORTSession(env: env, modelPath: "\(onnxDir)/vocoder.onnx", sessionOptions: sessionOptions)

    let unicodeIndexerPath = "\(onnxDir)/unicode_indexer.json"
    let textProcessor = try SupertonicUnicodeProcessor(unicodeIndexerPath: unicodeIndexerPath)

    return SupertonicTTS(
        env: env, cfgs: cfgs, textProcessor: textProcessor,
        dpOrt: dpOrt, textEncOrt: textEncOrt,
        vectorEstOrt: vectorEstOrt, vocoderOrt: vocoderOrt)
}
