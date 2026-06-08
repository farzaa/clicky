//
//  DummyMemorySeeder.swift
//  leanring-buddy
//
//  Seeds sample teaching skills as memories for local UI testing.
//  DEBUG builds only — adds any dummy entries not already on disk.
//

import Foundation

enum DummyMemorySeeder {
    static func seedMissingDummyMemories(store: TeachingSkillStore) {
        #if DEBUG
        let dummySkills = makeDummySkills()
        var seededCount = 0

        for dummySkill in dummySkills where store.skill(withID: dummySkill.id) == nil {
            try? store.saveSkill(dummySkill)
            seededCount += 1
        }

        guard seededCount > 0 else { return }
        print("🧪 Seeded \(seededCount) dummy memories for UI testing")
        #endif
    }

    #if DEBUG
    private static func makeDummySkills() -> [TeachingSkill] {
        [
            TeachingSkill(
                id: "teach-textedit-save",
                name: "Save a document in TextEdit",
                description: "Walk through saving the current document to disk",
                bundleIds: ["com.apple.TextEdit"],
                status: .active,
                lastUsed: Date().addingTimeInterval(-86400),
                usageCount: 5,
                isPinned: false,
                taskSlug: "save",
                body: """
                1. Click **File** in the menu bar.
                2. Choose **Save** (or press ⌘S).
                3. Pick a folder and filename, then click **Save**.
                """
            ),
            TeachingSkill(
                id: "teach-xcode-commit",
                name: "Commit changes in Xcode",
                description: "Stage and commit your current changes via Source Control",
                bundleIds: ["com.apple.dt.Xcode"],
                status: .active,
                lastUsed: Date().addingTimeInterval(-172800),
                usageCount: 3,
                isPinned: false,
                taskSlug: "commit",
                body: """
                1. Open the **Source Control** navigator (⌘2).
                2. Review changed files and check the ones to include.
                3. Enter a commit message and click **Commit**.
                """
            ),
            TeachingSkill(
                id: "teach-finder-new-folder",
                name: "Create a new folder in Finder",
                description: "Make a new folder in the current Finder window",
                bundleIds: ["com.apple.finder"],
                status: .stale,
                lastUsed: Date().addingTimeInterval(-604800),
                usageCount: 1,
                isPinned: false,
                taskSlug: "new-folder",
                body: """
                1. In Finder, go to the location where you want the folder.
                2. Choose **File → New Folder** (⇧⌘N).
                3. Type the folder name and press Return.
                """
            ),
            TeachingSkill(
                id: "teach-safari-bookmark",
                name: "Bookmark a page in Safari",
                description: "Save the current tab as a bookmark for later",
                bundleIds: ["com.apple.Safari"],
                status: .archived,
                lastUsed: Date().addingTimeInterval(-1209600),
                usageCount: 2,
                isPinned: false,
                taskSlug: "bookmark",
                body: """
                1. With the page open, click the **Share** button in the toolbar.
                2. Choose **Add Bookmark**.
                3. Name it and pick a folder, then click **Add**.
                """
            )
        ]
    }
    #endif
}
