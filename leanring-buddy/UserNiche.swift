//
//  UserNiche.swift
//  leanring-buddy
//
//  User-selected niche for onboarding and suggestion cards.
//

import Foundation

enum UserNiche: String, CaseIterable, Identifiable, Codable {
    case general
    case contentCreator
    case developer
    case student
    case designer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .contentCreator: return "Content creator"
        case .developer: return "Developer"
        case .student: return "Student"
        case .designer: return "Designer"
        }
    }

    var jsonKey: String {
        switch self {
        case .general: return "general"
        case .contentCreator: return "contentCreator"
        case .developer: return "developer"
        case .student: return "student"
        case .designer: return "designer"
        }
    }
}
