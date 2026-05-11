//
//  MacSpaceController.swift
//  leanring-buddy
//
//  Switches macOS Spaces using the private CoreGraphics Services (CGS) API.
//
//  Why this exists: posting ctrl+→ / ctrl+← via CGEvent (Dot's previous
//  approach) is silently filtered by macOS Sequoia+ for the Mission
//  Control / Spaces shortcuts. Even processes with Accessibility
//  permission see "key posted successfully" with no Space change. The
//  private CGSManagedDisplaySetCurrentSpace call switches reliably,
//  doesn't require Accessibility, and is what every serious window
//  manager (Yabai, Spectacle, Phoenix, Magnet, kwm) uses for the same
//  reason.
//
//  Stability: the CGS API is "private but stable" — these specific
//  symbols have existed since Mac OS X 10.6 and are still working as of
//  macOS 15. If Apple ever removes them, our fallback story is to fire
//  ctrl+arrow via CGEvent again and accept that it may not work on
//  some systems.
//

import AppKit
import CoreGraphics

// MARK: - Private CGS symbol bindings

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(
    _ cid: CGSConnectionID,
    _ displayUUID: CFString,
    _ spaceID: UInt64
) -> CGError

// MARK: - Public API

enum MacSpaceSwitchDirection: String {
    case next
    case previous
}

enum MacSpaceController {
    /// One Space, including the kind (regular desktop vs full-screen app)
    /// so the caller can choose to skip past full-screen Spaces if it
    /// wants — for our agent, we let Claude navigate to any Space.
    struct SpaceDescriptor {
        let managedSpaceID: UInt64
        /// 0 = regular desktop, 4 = full-screen app, etc. The kind values
        /// aren't fully documented; we leave them opaque and only act on
        /// "is this the current one" comparisons.
        let kind: Int
    }

    /// All Spaces on the display that currently contains the active Space.
    /// In single-display setups this is just "all your Spaces."
    static func enumerateSpacesOnActiveDisplay() -> (displayUUID: String, spaces: [SpaceDescriptor])? {
        let connectionID = CGSMainConnectionID()
        let activeSpaceID = CGSGetActiveSpace(connectionID)
        guard let displaysArray = CGSCopyManagedDisplaySpaces(connectionID) as? [[String: Any]] else {
            return nil
        }

        for displayDictionary in displaysArray {
            guard let displayUUID = displayDictionary["Display Identifier"] as? String,
                  let spacesArray = displayDictionary["Spaces"] as? [[String: Any]] else {
                continue
            }
            let parsedSpaces = spacesArray.compactMap { spaceDictionary -> SpaceDescriptor? in
                guard let managedSpaceIDValue = spaceDictionary["ManagedSpaceID"] as? Int else {
                    return nil
                }
                let kindValue = (spaceDictionary["type"] as? Int) ?? -1
                return SpaceDescriptor(
                    managedSpaceID: UInt64(managedSpaceIDValue),
                    kind: kindValue
                )
            }
            let containsActiveSpace = parsedSpaces.contains { $0.managedSpaceID == activeSpaceID }
            if containsActiveSpace {
                return (displayUUID, parsedSpaces)
            }
        }

        // Fallback: no display claimed the active space (shouldn't happen on
        // real hardware, but defensive). Return the first display.
        guard let firstDisplay = displaysArray.first,
              let firstDisplayUUID = firstDisplay["Display Identifier"] as? String,
              let firstSpacesArray = firstDisplay["Spaces"] as? [[String: Any]] else {
            return nil
        }
        let firstParsedSpaces = firstSpacesArray.compactMap { spaceDictionary -> SpaceDescriptor? in
            guard let managedSpaceIDValue = spaceDictionary["ManagedSpaceID"] as? Int else {
                return nil
            }
            let kindValue = (spaceDictionary["type"] as? Int) ?? -1
            return SpaceDescriptor(
                managedSpaceID: UInt64(managedSpaceIDValue),
                kind: kindValue
            )
        }
        return (firstDisplayUUID, firstParsedSpaces)
    }

    /// Index (0-based) of the currently active Space within the active
    /// display's Space list. Returns nil if the active Space isn't on any
    /// display we could enumerate (shouldn't happen in practice).
    static func indexOfCurrentSpaceOnActiveDisplay() -> (
        displayUUID: String,
        spaces: [SpaceDescriptor],
        currentIndex: Int
    )? {
        let connectionID = CGSMainConnectionID()
        let activeSpaceID = CGSGetActiveSpace(connectionID)
        guard let enumeration = enumerateSpacesOnActiveDisplay() else {
            return nil
        }
        guard let activeIndex = enumeration.spaces.firstIndex(
            where: { $0.managedSpaceID == activeSpaceID }
        ) else {
            return nil
        }
        return (enumeration.displayUUID, enumeration.spaces, activeIndex)
    }

    /// Result of a switch attempt — used by callers (and the agent's
    /// tool_result content) so Claude knows whether to retry or stop.
    struct SwitchResult {
        let didSwitch: Bool
        let resultDescription: String
        let previousSpaceID: UInt64?
        let newSpaceID: UInt64?
    }

    /// Switch to the Space immediately to the left or right of the current
    /// one on the active display. If the user is already at the leftmost
    /// (for `.previous`) or rightmost (for `.next`) Space, this is a
    /// no-op and `didSwitch` is false — we deliberately do NOT wrap
    /// around, matching macOS's own ctrl+→ behaviour at the edges.
    @discardableResult
    static func switchToAdjacentSpace(direction: MacSpaceSwitchDirection) -> SwitchResult {
        let connectionID = CGSMainConnectionID()
        let previousActiveSpaceID = CGSGetActiveSpace(connectionID)

        guard let snapshot = indexOfCurrentSpaceOnActiveDisplay() else {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "couldn't enumerate spaces — private CGS API returned no displays",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        let targetIndex: Int
        switch direction {
        case .next:
            targetIndex = snapshot.currentIndex + 1
        case .previous:
            targetIndex = snapshot.currentIndex - 1
        }

        guard targetIndex >= 0, targetIndex < snapshot.spaces.count else {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "already at the \(direction == .next ? "rightmost" : "leftmost") space (no more to \(direction.rawValue))",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        let targetSpaceID = snapshot.spaces[targetIndex].managedSpaceID
        let switchError = CGSManagedDisplaySetCurrentSpace(
            connectionID,
            snapshot.displayUUID as CFString,
            targetSpaceID
        )

        if switchError != .success {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "CGSManagedDisplaySetCurrentSpace returned error \(switchError.rawValue)",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        // CGSGetActiveSpace lags ~10ms behind the set call while the
        // WindowServer propagates the change. Polling for up to 300ms gives
        // the OS plenty of slack without making the agent feel sluggish; in
        // the common case we exit on the first poll iteration.
        let propagationDeadline = Date().addingTimeInterval(0.3)
        var resultingActiveSpaceID = previousActiveSpaceID
        repeat {
            usleep(15_000)
            resultingActiveSpaceID = CGSGetActiveSpace(connectionID)
            if resultingActiveSpaceID == targetSpaceID { break }
        } while Date() < propagationDeadline
        let didActuallySwitch = resultingActiveSpaceID == targetSpaceID

        return SwitchResult(
            didSwitch: didActuallySwitch,
            resultDescription: didActuallySwitch
                ? "switched to space at index \(targetIndex + 1) of \(snapshot.spaces.count)"
                : "set call returned success but active space did not propagate within 300ms",
            previousSpaceID: previousActiveSpaceID,
            newSpaceID: resultingActiveSpaceID
        )
    }

    /// Switch to the Space at the given 1-based index on the active display.
    /// 1 is the leftmost Space, 9 is the ninth. Returns no-switch if the
    /// index is out of range or already current.
    @discardableResult
    static func switchToSpaceAt(oneBasedIndex requestedIndex: Int) -> SwitchResult {
        let connectionID = CGSMainConnectionID()
        let previousActiveSpaceID = CGSGetActiveSpace(connectionID)

        guard let snapshot = enumerateSpacesOnActiveDisplay() else {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "couldn't enumerate spaces",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        let zeroBasedIndex = requestedIndex - 1
        guard zeroBasedIndex >= 0, zeroBasedIndex < snapshot.spaces.count else {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "space index \(requestedIndex) is out of range (you have \(snapshot.spaces.count) spaces)",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        let targetSpaceID = snapshot.spaces[zeroBasedIndex].managedSpaceID
        if targetSpaceID == previousActiveSpaceID {
            return SwitchResult(
                didSwitch: false,
                resultDescription: "already on space \(requestedIndex)",
                previousSpaceID: previousActiveSpaceID,
                newSpaceID: previousActiveSpaceID
            )
        }

        let switchError = CGSManagedDisplaySetCurrentSpace(
            connectionID,
            snapshot.displayUUID as CFString,
            targetSpaceID
        )

        // Wait for the active-space readback to propagate — see the
        // identical poll in switchToAdjacentSpace for the rationale.
        let propagationDeadline = Date().addingTimeInterval(0.3)
        var resultingActiveSpaceID = previousActiveSpaceID
        repeat {
            usleep(15_000)
            resultingActiveSpaceID = CGSGetActiveSpace(connectionID)
            if resultingActiveSpaceID == targetSpaceID { break }
        } while Date() < propagationDeadline
        let didActuallySwitch = switchError == .success && resultingActiveSpaceID == targetSpaceID

        return SwitchResult(
            didSwitch: didActuallySwitch,
            resultDescription: didActuallySwitch
                ? "switched to space \(requestedIndex) of \(snapshot.spaces.count)"
                : "switch failed (CGS error \(switchError.rawValue), active=\(resultingActiveSpaceID))",
            previousSpaceID: previousActiveSpaceID,
            newSpaceID: resultingActiveSpaceID
        )
    }
}
