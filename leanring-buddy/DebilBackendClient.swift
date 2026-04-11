import Foundation

enum DebilJSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: DebilJSONValue])
    case array([DebilJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
            return
        }
        if let objectValue = try? container.decode([String: DebilJSONValue].self) {
            self = .object(objectValue)
            return
        }
        if let arrayValue = try? container.decode([DebilJSONValue].self) {
            self = .array(arrayValue)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let stringValue):
            try container.encode(stringValue)
        case .number(let numberValue):
            try container.encode(numberValue)
        case .bool(let boolValue):
            try container.encode(boolValue)
        case .object(let objectValue):
            try container.encode(objectValue)
        case .array(let arrayValue):
            try container.encode(arrayValue)
        case .null:
            try container.encodeNil()
        }
    }
}

struct DebilAuthenticatedUser: Codable, Hashable, Identifiable {
    let id: String
    let emailAddress: String
    let displayName: String?
}

struct DebilAuthSessionResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresAt: Date
    let user: DebilAuthenticatedUser
}

struct DebilWorkspace: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let launchState: String
    let launchedAt: Date?
    let lastOpenedAt: Date?
    let membershipRole: String
    let workspaceMetadata: [String: DebilJSONValue]

    var isRunning: Bool {
        launchState.lowercased() == "running"
    }
}

struct DebilWorkspaceEntry: Codable, Hashable, Identifiable {
    let id: String
    let workspaceID: String
    let entryName: String
    let entryPath: String
    let entryType: String
    let contentType: String?
    let mimeType: String?
    let sizeBytes: Int?
    let contentSha256: String?
    let entryMetadata: [String: DebilJSONValue]?

    var isDirectory: Bool {
        entryType.lowercased() == "directory"
    }
}

struct DebilWorkspaceEntriesListResponse: Codable {
    let workspaceID: String
    let parentEntryPath: String
    let entries: [DebilWorkspaceEntry]
}

struct DebilWorkspaceFileReadResponse: Codable {
    let id: String
    let workspaceID: String
    let entryName: String
    let entryPath: String
    let entryType: String
    let contentType: String?
    let mimeType: String?
    let sizeBytes: Int?
    let hasBinaryContent: Bool
    let textContent: String?
    let binaryContentBase64: String?
}

enum DebilBackendClientError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURLString):
            return "Invalid backend URL: \(baseURLString)"
        case .invalidResponse:
            return "Backend returned an invalid response."
        case .httpError(let statusCode, let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedMessage.isEmpty {
                return "Backend request failed with status \(statusCode)."
            }
            return "Backend request failed (\(statusCode)): \(trimmedMessage)"
        }
    }
}

struct DebilBackendClient {
    private let baseURLString: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURLString: String, session: URLSession = .shared) {
        self.baseURLString = baseURLString
        self.session = session

        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder
    }

    func register(
        emailAddress: String,
        password: String,
        displayName: String?
    ) async throws -> DebilAuthSessionResponse {
        var request = try makeRequest(path: "/auth/register", method: "POST")
        var payload: [String: Any] = [
            "email_address": emailAddress,
            "password": password,
        ]
        payload["display_name"] = displayName ?? NSNull()
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload,
            options: []
        )
        return try await sendJSON(request, responseType: DebilAuthSessionResponse.self)
    }

    func login(
        emailAddress: String,
        password: String
    ) async throws -> DebilAuthSessionResponse {
        var request = try makeRequest(path: "/auth/login", method: "POST")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "email_address": emailAddress,
                "password": password,
            ],
            options: []
        )
        return try await sendJSON(request, responseType: DebilAuthSessionResponse.self)
    }

    func me(accessToken: String) async throws -> DebilAuthenticatedUser {
        let request = try makeRequest(
            path: "/auth/me",
            method: "GET",
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: DebilAuthenticatedUser.self)
    }

    func logout(accessToken: String) async throws {
        let request = try makeRequest(
            path: "/auth/logout",
            method: "POST",
            accessToken: accessToken
        )
        _ = try await sendData(request)
    }

    func listWorkspaces(accessToken: String) async throws -> [DebilWorkspace] {
        let request = try makeRequest(
            path: "/workspaces/",
            method: "GET",
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: [DebilWorkspace].self)
    }

    func createWorkspace(
        accessToken: String,
        displayName: String
    ) async throws -> DebilWorkspace {
        var request = try makeRequest(
            path: "/workspaces/",
            method: "POST",
            accessToken: accessToken
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "display_name": displayName,
                "workspace_metadata": [:],
            ],
            options: []
        )
        return try await sendJSON(request, responseType: DebilWorkspace.self)
    }

    func launchWorkspace(accessToken: String, workspaceID: String) async throws -> DebilWorkspace {
        let request = try makeRequest(
            path: "/workspaces/\(workspaceID)/launch",
            method: "POST",
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: DebilWorkspace.self)
    }

    func stopWorkspace(accessToken: String, workspaceID: String) async throws -> DebilWorkspace {
        let request = try makeRequest(
            path: "/workspaces/\(workspaceID)/stop",
            method: "POST",
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: DebilWorkspace.self)
    }

    func listWorkspaceEntries(
        accessToken: String,
        workspaceID: String,
        parentEntryPath: String
    ) async throws -> DebilWorkspaceEntriesListResponse {
        let request = try makeRequest(
            path: "/workspaces/\(workspaceID)/entries",
            method: "GET",
            queryItems: [URLQueryItem(name: "parent_entry_path", value: parentEntryPath)],
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: DebilWorkspaceEntriesListResponse.self)
    }

    func readWorkspaceFile(
        accessToken: String,
        workspaceID: String,
        entryPath: String
    ) async throws -> DebilWorkspaceFileReadResponse {
        let request = try makeRequest(
            path: "/workspaces/\(workspaceID)/entries/read",
            method: "GET",
            queryItems: [URLQueryItem(name: "entry_path", value: entryPath)],
            accessToken: accessToken
        )
        return try await sendJSON(request, responseType: DebilWorkspaceFileReadResponse.self)
    }

    func uploadWorkspaceFile(
        accessToken: String,
        workspaceID: String,
        entryPath: String,
        fileName: String,
        fileData: Data,
        mimeType: String?
    ) async throws -> DebilWorkspaceEntry {
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        var request = try makeRequest(
            path: "/workspaces/\(workspaceID)/entries/upload",
            method: "POST",
            accessToken: accessToken,
            contentType: "multipart/form-data; boundary=\(multipartBoundary)"
        )

        var requestBody = Data()
        requestBody.appendMultipartFormField(
            named: "entry_path",
            value: entryPath,
            usingBoundary: multipartBoundary
        )
        if let mimeType, !mimeType.isEmpty {
            requestBody.appendMultipartFormField(
                named: "mime_type",
                value: mimeType,
                usingBoundary: multipartBoundary
            )
        }
        requestBody.appendMultipartFileField(
            named: "file",
            filename: fileName,
            mimeType: mimeType ?? "application/octet-stream",
            fileData: fileData,
            usingBoundary: multipartBoundary
        )
        requestBody.appendString("--\(multipartBoundary)--\r\n")
        request.httpBody = requestBody

        return try await sendJSON(request, responseType: DebilWorkspaceEntry.self)
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String? = nil,
        contentType: String = "application/json"
    ) throws -> URLRequest {
        guard var urlComponents = URLComponents(string: baseURLString) else {
            throw DebilBackendClientError.invalidBaseURL(baseURLString)
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let currentPath = urlComponents.path.isEmpty ? "" : urlComponents.path
        let joinedPath = (currentPath + normalizedPath).replacingOccurrences(
            of: "//",
            with: "/"
        )
        urlComponents.path = joinedPath
        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw DebilBackendClientError.invalidBaseURL(baseURLString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sendJSON<ResponseType: Decodable>(
        _ request: URLRequest,
        responseType: ResponseType.Type
    ) async throws -> ResponseType {
        let responseData = try await sendData(request)
        do {
            return try decoder.decode(ResponseType.self, from: responseData)
        } catch {
            throw DebilBackendClientError.httpError(
                statusCode: 500,
                message: "Failed to decode backend response: \(error.localizedDescription)"
            )
        }
    }

    private func sendData(_ request: URLRequest) async throws -> Data {
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DebilBackendClientError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? ""
            throw DebilBackendClientError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
        return responseData
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendMultipartFormField(
        named fieldName: String,
        value: String,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFileField(
        named fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}
