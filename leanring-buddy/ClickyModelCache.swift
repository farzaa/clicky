//
//  ClickyModelCache.swift
//  leanring-buddy
//
//  Single source of truth for where on-device models live. Application
//  Support (not Caches) so macOS doesn't purge multi-GB weights under disk
//  pressure. Shared by the local chat provider and the takeover vision agent.
//

import Foundation

enum ClickyModelCache {
    /// `~/Library/Application Support/Clicky/models/huggingface`, created if needed.
    static func huggingFaceCacheDirectory() throws -> URL {
        let applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }
}
