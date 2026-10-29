//
//  ClickyTestHomeIsolation.swift
//  leanring-buddyTests
//
//  Serializes access to the process-wide `ClickyPaths.overrideHomeForTesting`
//  global across ALL test suites. `@Suite(.serialized)` only serializes tests
//  within a single suite, but Swift Testing still runs separate suites in
//  parallel in-process. Without a shared lock, one suite can reset the override
//  while another suite is mid-test (e.g. between `save` and `loadAllSessions`),
//  causing the store to resolve a different home directory than it wrote to.
//

import Foundation
@testable import leanring_buddy

enum ClickyTestHomeIsolation {
    private static let lock = NSLock()

    /// Runs `body` with `ClickyPaths.overrideHomeForTesting` set to `home`,
    /// holding a process-wide lock so no other suite can mutate the global
    /// for the duration. The override is always cleared afterwards.
    static func withIsolatedHome<ResultType>(
        _ home: URL,
        _ body: () throws -> ResultType
    ) rethrows -> ResultType {
        lock.lock()
        defer { lock.unlock() }

        let previousOverride = ClickyPaths.overrideHomeForTesting
        ClickyPaths.overrideHomeForTesting = home
        defer { ClickyPaths.overrideHomeForTesting = previousOverride }

        return try body()
    }

    /// Runs `body` while holding the same lock without setting an override,
    /// for tests that assert the production default home resolution.
    static func withSerializedHomeAccess<ResultType>(
        _ body: () throws -> ResultType
    ) rethrows -> ResultType {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
