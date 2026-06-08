//
//  VaultDiscoveryService.swift
//  leanring-buddy
//
//  Finds Obsidian vaults registered on this Mac via obsidian.json.
//

import Foundation

struct DiscoveredVault: Identifiable, Equatable {
    let id: String
    let displayName: String
    let path: String

    var folderURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

enum VaultDiscoveryService {
    private static let obsidianConfigURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }()

    /// Reads Obsidian's vault registry and returns paths that still exist on disk.
    static func discoverObsidianVaults() -> [DiscoveredVault] {
        var discoveredVaults = parseObsidianRegistry()
        discoveredVaults.append(contentsOf: discoverVaultsInCommonLocations(existingPaths: Set(discoveredVaults.map(\.path))))

        var seenPaths = Set<String>()
        return discoveredVaults.filter { vault in
            let normalizedPath = (vault.path as NSString).standardizingPath
            guard !seenPaths.contains(normalizedPath) else { return false }
            seenPaths.insert(normalizedPath)
            return FileManager.default.fileExists(atPath: normalizedPath)
        }
    }

    private static func parseObsidianRegistry() -> [DiscoveredVault] {
        guard let data = try? Data(contentsOf: obsidianConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaultsObject = json["vaults"] as? [String: Any] else {
            return []
        }

        var discoveredVaults: [DiscoveredVault] = []

        for (vaultID, vaultValue) in vaultsObject {
            guard let vaultDictionary = vaultValue as? [String: Any],
                  let path = vaultDictionary["path"] as? String else {
                continue
            }

            let displayName = (path as NSString).lastPathComponent
            discoveredVaults.append(
                DiscoveredVault(id: vaultID, displayName: displayName, path: path)
            )
        }

        return discoveredVaults.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Shallow fallback when Obsidian's registry is missing or incomplete.
    private static func discoverVaultsInCommonLocations(existingPaths: Set<String>) -> [DiscoveredVault] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidateRoots = [
            homeDirectory.appendingPathComponent("Documents", isDirectory: true),
            homeDirectory.appendingPathComponent("Notes", isDirectory: true),
            homeDirectory.appendingPathComponent("Obsidian", isDirectory: true)
        ]

        var discoveredVaults: [DiscoveredVault] = []
        let fileManager = FileManager.default

        for rootURL in candidateRoots where fileManager.fileExists(atPath: rootURL.path) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entryURL in entries {
                let standardizedPath = (entryURL.path as NSString).standardizingPath
                guard !existingPaths.contains(standardizedPath) else { continue }

                guard fileManager.fileExists(atPath: entryURL.path),
                      (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                let obsidianConfigFolder = entryURL.appendingPathComponent(".obsidian", isDirectory: true)
                guard fileManager.fileExists(atPath: obsidianConfigFolder.path) else { continue }

                discoveredVaults.append(
                    DiscoveredVault(
                        id: standardizedPath,
                        displayName: entryURL.lastPathComponent,
                        path: standardizedPath
                    )
                )
            }
        }

        return discoveredVaults
    }
}
