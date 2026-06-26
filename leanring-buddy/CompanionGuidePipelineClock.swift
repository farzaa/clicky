//
//  CompanionGuidePipelineClock.swift
//  leanring-buddy
//
//  Shared timing helper for the screen-guidance request pipeline.
//

import Foundation

enum CompanionGuidePipelineClock {
    static func elapsedMilliseconds(since startDate: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startDate) * 1000))
    }
}
