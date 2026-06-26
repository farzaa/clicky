//
//  GroundingLocalOCRSensor.swift
//  leanring-buddy
//
//  Local OCR confirmation for Vision-selected targets. OCR text is used only
//  in-memory to confirm or contradict the target and is never telemetry.
//

import AppKit
import Foundation
import Vision

enum GroundingLocalOCRSensor {
    static func signal(
        guidePoint: SpiderGuidePoint,
        projection: GroundingPointProjection?,
        target: SpiderGuideSemanticTarget?,
        policy: GroundingSensorFusionPolicy
    ) -> GroundingAuxiliarySignal {
        guard let projection,
              let targetRegion = target?.region,
              let expectedLabel = guidePoint.label ?? target?.label,
              !expectedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsSensitiveComparableText(expectedLabel) else {
            return .unavailable(.localOCR)
        }

        let expectedTokens = comparableTokens(
            from: expectedLabel,
            minimumLength: policy.minimumOCRTokenCharacters
        )
        guard !expectedTokens.isEmpty else {
            return .unavailable(.localOCR)
        }

        let recognizedCandidates = recognizedTextNearTarget(
            capture: projection.capture,
            targetRegion: targetRegion,
            policy: policy
        )
        return signal(
            expectedLabel: expectedLabel,
            candidates: recognizedCandidates,
            policy: policy
        )
    }

    static func signal(
        expectedLabel: String,
        candidates: [GroundingOCRCandidate],
        policy: GroundingSensorFusionPolicy
    ) -> GroundingAuxiliarySignal {
        guard !candidates.isEmpty else {
            return .inconclusive(.localOCR)
        }

        let expectedTokens = comparableTokens(
            from: expectedLabel,
            minimumLength: policy.minimumOCRTokenCharacters
        )
        guard !expectedTokens.isEmpty else {
            return .unavailable(.localOCR)
        }

        let recognizedTokens = candidates.flatMap {
            comparableTokens(from: $0.text, minimumLength: policy.minimumOCRTokenCharacters)
        }
        guard !recognizedTokens.isEmpty else {
            return .inconclusive(.localOCR)
        }

        let expectedTokenSet = Set(expectedTokens)
        let hasTokenOverlap = recognizedTokens.contains { expectedTokenSet.contains($0) }
        let recognizedJoined = candidates
            .map { normalizedComparableText($0.text) }
            .joined(separator: " ")
        let expectedJoined = normalizedComparableText(expectedLabel)

        if hasTokenOverlap || recognizedJoined.contains(expectedJoined) || expectedJoined.contains(recognizedJoined) {
            return .confirmed(.localOCR)
        }

        let averageConfidence = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        let uniqueRecognizedTokenCount = Set(recognizedTokens).count
        guard candidates.count >= policy.ocrStrongMismatchMinimumCandidates,
              uniqueRecognizedTokenCount >= policy.ocrStrongMismatchMinimumTokenCount,
              averageConfidence >= policy.ocrStrongMismatchMinimumAverageConfidence else {
            return .inconclusive(.localOCR)
        }

        return .contradicted(.localOCR, [.ocrTextMismatch])
    }

    private static func recognizedTextNearTarget(
        capture: CompanionScreenCapture,
        targetRegion: SpiderGuideRegion,
        policy: GroundingSensorFusionPolicy
    ) -> [GroundingOCRCandidate] {
        guard let nsImage = NSImage(data: capture.imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let paddedRegion = targetRegion.rect.insetBy(
            dx: -policy.ocrRegionPaddingPixels,
            dy: -policy.ocrRegionPaddingPixels
        )
        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let cropRect = paddedRegion.intersection(imageBounds).integral
        guard !cropRect.isNull,
              cropRect.width > 1,
              cropRect.height > 1,
              let croppedImage = cgImage.cropping(to: cropRect) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        do {
            try VNImageRequestHandler(cgImage: croppedImage, options: [:]).perform([request])
        } catch {
            return []
        }

        return (request.results ?? [])
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= policy.ocrMinimumConfidence else {
                    return nil
                }
                return GroundingOCRCandidate(text: candidate.string, confidence: candidate.confidence)
            }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func comparableTokens(from value: String, minimumLength: Int) -> [String] {
        normalizedComparableText(value)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= minimumLength }
    }

    private static func normalizedComparableText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsSensitiveComparableText(_ value: String) -> Bool {
        value.range(
            of: #"[@]|\b\d{4,}\b|password|senha|token|code|codigo|código|card|cart[aã]o"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
