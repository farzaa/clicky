//
//  SpiderDiagnostics.swift
//  leanring-buddy
//
//  DEBUG-only diagnostic logging. Do not pass user content, URLs, tokens,
//  transcripts, prompts, screenshots, model responses, or raw Error values.
//

import Foundation

enum SpiderDiagnostics {
    static func event(_ message: StaticString) {
        #if DEBUG
        print("Spider diagnostic: \(message)")
        #endif
    }

    static func guidePointIgnored(_ reason: SpiderGuidePointRejectionReason) {
        #if DEBUG
        print("Spider diagnostic: guide point ignored: \(reason.rawValue)")
        #endif
    }

    static func count(_ name: StaticString, _ value: Int) {
        #if DEBUG
        print("Spider diagnostic: \(name)=\(value)")
        #endif
    }

    static func flag(_ name: StaticString, _ value: Bool) {
        #if DEBUG
        print("Spider diagnostic: \(name)=\(value)")
        #endif
    }

    static func workerFailure(_ operation: StaticString, statusCode: Int) {
        #if DEBUG
        print("Spider diagnostic: \(operation) failed with worker_status=\(statusCode)")
        #endif
    }
}
