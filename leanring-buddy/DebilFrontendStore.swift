import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DebilFrontendStore {
    private(set) var currentUser: DebilAuthenticatedUser?
    private(set) var workspaces: [DebilWorkspace] = []
    private(set) var selectedWorkspaceID: String?
    private(set) var currentDirectoryPath: String = "/"
    private(set) var currentEntries: [DebilWorkspaceEntry] = []
    private(set) var selectedFilePath: String?
    private(set) var selectedFilePreviewText: String?
    private(set) var selectedFileHasBinaryContent = false

    private(set) var isAuthenticating = false
    private(set) var isLoadingWorkspaces = false
    private(set) var isLoadingEntries = false
    private(set) var isUploadingFiles = false

    var authErrorMessage: String?
    var workspaceErrorMessage: String?
    var statusMessage: String?

    private let backendClient: DebilBackendClient
    private var authToken: String? {
        didSet {
            if let authToken, !authToken.isEmpty {
                UserDefaults.standard.set(authToken, forKey: Self.authTokenUserDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.authTokenUserDefaultsKey)
            }
        }
    }

    private static let authTokenUserDefaultsKey = "debilFrontendAuthToken"

    var isAuthenticated: Bool {
        authToken != nil && currentUser != nil
    }

    var selectedWorkspace: DebilWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == selectedWorkspaceID })
    }

    init(backendClient: DebilBackendClient = DebilBackendClient(baseURLString: AppBundleConfiguration.backendBaseURL())) {
        self.backendClient = backendClient
        self.authToken = UserDefaults.standard.string(forKey: Self.authTokenUserDefaultsKey)

        Task { [weak self] in
            await self?.restoreSessionIfNeeded()
        }
    }

    func signIn(emailAddress: String, password: String) async {
        let normalizedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmailAddress.isEmpty, !password.isEmpty else {
            authErrorMessage = "Enter your email and password."
            return
        }

        isAuthenticating = true
        authErrorMessage = nil
        statusMessage = nil
        defer { isAuthenticating = false }

        do {
            let authSessionResponse = try await backendClient.login(
                emailAddress: normalizedEmailAddress,
                password: password
            )
            applyAuthenticatedSession(authSessionResponse)
            await refreshWorkspaces()
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func signUp(
        emailAddress: String,
        password: String,
        displayName: String
    ) async {
        let normalizedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEmailAddress.isEmpty, !password.isEmpty else {
            authErrorMessage = "Enter your email and password."
            return
        }

        isAuthenticating = true
        authErrorMessage = nil
        statusMessage = nil
        defer { isAuthenticating = false }

        do {
            let authSessionResponse = try await backendClient.register(
                emailAddress: normalizedEmailAddress,
                password: password,
                displayName: normalizedDisplayName.isEmpty ? nil : normalizedDisplayName
            )
            applyAuthenticatedSession(authSessionResponse)
            await refreshWorkspaces()
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        if let authToken {
            try? await backendClient.logout(accessToken: authToken)
        }
        clearSessionState()
        statusMessage = "Signed out."
    }

    func refreshWorkspaces() async {
        guard let authToken else { return }

        isLoadingWorkspaces = true
        workspaceErrorMessage = nil
        defer { isLoadingWorkspaces = false }

        do {
            let fetchedWorkspaces = try await backendClient.listWorkspaces(accessToken: authToken)
            workspaces = fetchedWorkspaces.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            if workspaces.isEmpty {
                selectedWorkspaceID = nil
                currentEntries = []
                currentDirectoryPath = "/"
                statusMessage = "No workspaces yet. Create your first course workspace."
                return
            }

            if selectedWorkspaceID == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = workspaces.first?.id
                currentDirectoryPath = "/"
            }

            if selectedWorkspace != nil {
                await loadEntries(at: currentDirectoryPath)
            }
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func createWorkspace(displayName: String) async {
        guard let authToken else { return }
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty else {
            workspaceErrorMessage = "Workspace name cannot be empty."
            return
        }

        isLoadingWorkspaces = true
        workspaceErrorMessage = nil
        defer { isLoadingWorkspaces = false }

        do {
            let createdWorkspace = try await backendClient.createWorkspace(
                accessToken: authToken,
                displayName: normalizedDisplayName
            )
            workspaces.append(createdWorkspace)
            workspaces.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            selectedWorkspaceID = createdWorkspace.id
            currentDirectoryPath = "/"
            statusMessage = "Created workspace \(createdWorkspace.displayName)."
            await loadEntries(at: "/")
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func toggleWorkspaceLaunchState(workspaceID: String) async {
        guard let authToken else { return }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }

        do {
            let updatedWorkspace: DebilWorkspace
            if workspace.isRunning {
                updatedWorkspace = try await backendClient.stopWorkspace(
                    accessToken: authToken,
                    workspaceID: workspaceID
                )
            } else {
                updatedWorkspace = try await backendClient.launchWorkspace(
                    accessToken: authToken,
                    workspaceID: workspaceID
                )
            }

            if let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) {
                workspaces[workspaceIndex] = updatedWorkspace
            }
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(withID workspaceID: String) async {
        selectedWorkspaceID = workspaceID
        currentDirectoryPath = "/"
        selectedFilePath = nil
        selectedFilePreviewText = nil
        selectedFileHasBinaryContent = false
        await loadEntries(at: "/")
    }

    func loadEntries(at parentEntryPath: String) async {
        guard let authToken else { return }
        guard let selectedWorkspaceID else { return }

        isLoadingEntries = true
        workspaceErrorMessage = nil
        defer { isLoadingEntries = false }

        do {
            let entriesResponse = try await backendClient.listWorkspaceEntries(
                accessToken: authToken,
                workspaceID: selectedWorkspaceID,
                parentEntryPath: parentEntryPath
            )
            currentDirectoryPath = entriesResponse.parentEntryPath
            currentEntries = entriesResponse.entries
            selectedFilePath = nil
            selectedFilePreviewText = nil
            selectedFileHasBinaryContent = false
            statusMessage = nil
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func openDirectory(_ workspaceEntry: DebilWorkspaceEntry) async {
        guard workspaceEntry.isDirectory else { return }
        await loadEntries(at: workspaceEntry.entryPath)
    }

    func navigateToParentDirectory() async {
        guard currentDirectoryPath != "/" else { return }
        let currentPathComponents = currentDirectoryPath
            .split(separator: "/")
            .map(String.init)
        let parentPathComponents = currentPathComponents.dropLast()
        let parentPath = parentPathComponents.isEmpty
            ? "/"
            : "/" + parentPathComponents.joined(separator: "/")
        await loadEntries(at: parentPath)
    }

    func readFile(_ workspaceEntry: DebilWorkspaceEntry) async {
        guard !workspaceEntry.isDirectory else { return }
        guard let authToken else { return }
        guard let selectedWorkspaceID else { return }

        do {
            let fileReadResponse = try await backendClient.readWorkspaceFile(
                accessToken: authToken,
                workspaceID: selectedWorkspaceID,
                entryPath: workspaceEntry.entryPath
            )
            selectedFilePath = fileReadResponse.entryPath
            selectedFileHasBinaryContent = fileReadResponse.hasBinaryContent

            if let textContent = fileReadResponse.textContent, !textContent.isEmpty {
                selectedFilePreviewText = textContent
            } else if fileReadResponse.hasBinaryContent {
                let fileSizeText = fileReadResponse.sizeBytes.map { "\($0) bytes" } ?? "unknown size"
                selectedFilePreviewText = "Binary file preview is not supported (\(fileSizeText))."
            } else {
                selectedFilePreviewText = "This file is empty."
            }
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func uploadFiles(_ fileURLs: [URL]) async {
        guard let authToken else { return }
        guard let selectedWorkspaceID else { return }
        guard !fileURLs.isEmpty else { return }

        isUploadingFiles = true
        workspaceErrorMessage = nil
        defer { isUploadingFiles = false }

        var uploadedFilesCount = 0
        var uploadFailures: [String] = []

        for fileURL in fileURLs {
            do {
                let fileData = try Data(contentsOf: fileURL)
                let entryPath = workspaceEntryPath(for: fileURL.lastPathComponent)
                let mimeType = inferMimeType(for: fileURL)
                _ = try await backendClient.uploadWorkspaceFile(
                    accessToken: authToken,
                    workspaceID: selectedWorkspaceID,
                    entryPath: entryPath,
                    fileName: fileURL.lastPathComponent,
                    fileData: fileData,
                    mimeType: mimeType
                )
                uploadedFilesCount += 1
            } catch {
                uploadFailures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if uploadedFilesCount > 0 {
            await loadEntries(at: currentDirectoryPath)
            statusMessage = "Uploaded \(uploadedFilesCount) file(s)."
        }

        if !uploadFailures.isEmpty {
            workspaceErrorMessage = uploadFailures.joined(separator: "\n")
        }
    }

    private func restoreSessionIfNeeded() async {
        guard let authToken else { return }

        do {
            currentUser = try await backendClient.me(accessToken: authToken)
            await refreshWorkspaces()
        } catch {
            clearSessionState()
            authErrorMessage = error.localizedDescription
        }
    }

    private func applyAuthenticatedSession(_ authSessionResponse: DebilAuthSessionResponse) {
        authToken = authSessionResponse.accessToken
        currentUser = authSessionResponse.user
        authErrorMessage = nil
        workspaceErrorMessage = nil
        statusMessage = nil
    }

    private func clearSessionState() {
        authToken = nil
        currentUser = nil
        workspaces = []
        selectedWorkspaceID = nil
        currentDirectoryPath = "/"
        currentEntries = []
        selectedFilePath = nil
        selectedFilePreviewText = nil
        selectedFileHasBinaryContent = false
        authErrorMessage = nil
        workspaceErrorMessage = nil
        statusMessage = nil
    }

    private func workspaceEntryPath(for fileName: String) -> String {
        let sanitizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentDirectoryPath == "/" {
            return "/" + sanitizedFileName
        }
        return currentDirectoryPath + "/" + sanitizedFileName
    }

    private func inferMimeType(for fileURL: URL) -> String? {
        guard !fileURL.pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
    }
}
