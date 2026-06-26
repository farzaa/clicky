//
//  CompanionPanelCopyTests.swift
//  leanring-buddyTests
//
//  Keeps localized panel copy fallback behavior stable while the panel view is split.
//

import Testing
@testable import Spider

struct CompanionPanelCopyTests {
    @Test func englishCopyFallsBackToTheSourceKey() {
        #expect(
            SpiderPanelCopy.text(
                "Spider shows what to click, what to avoid,\nand when to stop before you spend.",
                language: .english
            )
                == "Spider shows what to click, what to avoid,\nand when to stop before you spend."
        )
    }

    @Test func localizedCopyReturnsConfiguredTranslation() {
        #expect(
            SpiderPanelCopy.text(
                "You click. Spider never spends.",
                language: .portuguese
            )
                == "Você clica. Spider nunca gasta."
        )
        #expect(
            SpiderPanelCopy.text(
                "Guide the current ads platform screen",
                language: .spanish
            )
                == "Guiar la pantalla actual de la plataforma de ads"
        )
    }

    @Test func missingLocalizedCopyFallsBackToTheSourceKey() {
        #expect(
            SpiderPanelCopy.text(
                "Untranslated runtime text",
                language: .portuguese
            )
                == "Untranslated runtime text"
        )
    }
}
