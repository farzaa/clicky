import Foundation
import Security

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: store-proxy-token.swift <token-file>\n", stderr)
    exit(2)
}

let tokenFileURL = URL(fileURLWithPath: CommandLine.arguments[1])
let tokenData = try Data(contentsOf: tokenFileURL)
guard !tokenData.isEmpty else {
    fputs("The Worker token file is empty.\n", stderr)
    exit(2)
}

let itemIdentity: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.clicky.proxy",
    kSecAttrAccount as String: "authorization-token"
]

let updateStatus = SecItemUpdate(
    itemIdentity as CFDictionary,
    [kSecValueData as String: tokenData] as CFDictionary
)

if updateStatus == errSecItemNotFound {
    var newItem = itemIdentity
    newItem[kSecValueData as String] = tokenData
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        fputs("Could not store the Worker token in Keychain (status \(addStatus)).\n", stderr)
        exit(1)
    }
} else if updateStatus != errSecSuccess {
    fputs("Could not update the Worker token in Keychain (status \(updateStatus)).\n", stderr)
    exit(1)
}

print("Worker token stored in macOS Keychain.")
