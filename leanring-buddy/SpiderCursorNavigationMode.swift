//
//  SpiderCursorNavigationMode.swift
//  leanring-buddy
//
//  Cursor companion navigation states used by the overlay view.
//

enum BuddyNavigationMode {
    /// Default: buddy follows the mouse cursor with spring animation.
    case followingCursor

    /// Buddy is animating toward a detected UI element location.
    case navigatingToTarget

    /// Buddy has arrived at the target and is pointing at it with a speech bubble.
    case pointingAtTarget
}
