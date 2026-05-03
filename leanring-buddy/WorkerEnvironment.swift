//
//  WorkerEnvironment.swift
//  leanring-buddy
//
//  Automatically detects if the local development Cloudflare Worker is running.
//  If yes, it connects to localhost out-of-the-box. Otherwise, it falls back to production.
//

import Foundation

actor WorkerEnvironment {
    static let shared = WorkerEnvironment()
    
    private var cachedBaseURL: String?
    
    // Replace this with your actual production Worker URL if known
    private let defaultProdURL = "https://your-worker-name.your-subdomain.workers.dev"
    
    func getBaseURL() async -> String {
        if let cached = cachedBaseURL {
            return cached
        }
        
        if let saved = UserDefaults.standard.string(forKey: "workerBaseURL"), !saved.isEmpty {
            cachedBaseURL = saved
            return saved // Allow optional user override
        }
        
        let localURL = "http://localhost:8787"
        var request = URLRequest(url: URL(string: localURL)!)
        request.httpMethod = "OPTIONS" // Quick lightweight pre-flight
        request.timeoutInterval = 0.5  // Fail very fast if it's not running
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse) != nil {
                print("🌐 Auto-detected local worker. Using \(localURL)")
                cachedBaseURL = localURL
                return localURL
            }
        } catch {
            print("🌐 Local worker unreachable. Falling back to prod: \(defaultProdURL)")
        }
        
        cachedBaseURL = defaultProdURL
        return defaultProdURL
    }
    
    func resetCache() {
        cachedBaseURL = nil
    }
}