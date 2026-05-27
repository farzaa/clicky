//
//  TeachingPromptBuilder.swift
//  leanring-buddy
//
//  Composes the voice response system prompt with matched teaching skills.
//

import Foundation

enum TeachingPromptBuilder {
    static func buildVoiceResponsePrompt(
        basePrompt: String,
        matchedSkills: [TeachingSkill],
        maxSkillCharacters: Int = 3500
    ) -> String {
        guard !matchedSkills.isEmpty else { return basePrompt }

        var usedCharacters = 0
        var renderedSkills: [String] = []

        for skill in matchedSkills {
            let rendered = skill.renderedMarkdown()
            if usedCharacters + rendered.count > maxSkillCharacters, !renderedSkills.isEmpty {
                break
            }
            renderedSkills.append(rendered)
            usedCharacters += rendered.count
        }

        guard !renderedSkills.isEmpty else { return basePrompt }

        return """
        \(basePrompt)

        teaching skills:
        the following local teaching notes were learned from earlier successful tutoring sessions on this mac. reuse them when they clearly apply. prefer the saved ui labels, menu paths, shortcuts, and pointing order over guessing.

        \(renderedSkills.joined(separator: "\n\n"))
        """
    }
}
