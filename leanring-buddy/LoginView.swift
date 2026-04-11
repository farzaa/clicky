import SwiftUI

struct LoginView: View {
    @Environment(DebilFrontendStore.self) private var frontendStore

    @State private var isSignUpMode = false
    @State private var shouldRevealPassword = false
    @State private var emailAddress = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var acceptedTerms = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                DebBuddyMarkView(
                    palette: .inApp,
                    rotationDegrees: 0,
                    scale: 1,
                    glowRadiusExtension: 0,
                    chipSide: 40,
                    iconMaxSize: 26
                )

                VStack(spacing: 4) {
                    Text(isSignUpMode ? "Create an account" : "Welcome to Deb")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.foreground)
                        .multilineTextAlignment(.center)

                    Text(
                        isSignUpMode
                            ? "Tag what you know and what you missed."
                            : "Bridge gaps from what you already know."
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 280)
                }

                VStack(spacing: 8) {
                    Button(action: handleGoogleButtonTap) {
                        HStack(spacing: 6) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 13))
                            Text(isSignUpMode ? "Continue with Google" : "Sign in with Google")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    HStack {
                        Rectangle().fill(DS.border).frame(height: 1)
                        Text(isSignUpMode ? "or sign up with email" : "or sign in with email")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.mutedForeground)
                        Rectangle().fill(DS.border).frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if isSignUpMode {
                            labeledField(title: "Name") {
                                TextField("Name", text: $displayName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(6)
                                    .background(DS.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border))
                            }
                        }

                        labeledField(title: "Email") {
                            HStack(spacing: 6) {
                                Image(systemName: "envelope")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.foreground.opacity(0.75))
                                TextField("Email", text: $emailAddress)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                            }
                            .padding(6)
                            .background(DS.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.foreground)

                            HStack(spacing: 6) {
                                Image(systemName: "lock")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.foreground.opacity(0.75))
                                Group {
                                    if shouldRevealPassword {
                                        TextField("Password", text: $password)
                                    } else {
                                        SecureField("Password", text: $password)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))

                                Button {
                                    shouldRevealPassword.toggle()
                                } label: {
                                    Image(systemName: shouldRevealPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.foreground.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(6)
                            .background(DS.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border))
                        }

                        if isSignUpMode {
                            Toggle(isOn: $acceptedTerms) {
                                Text("I agree to Terms")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.foreground)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    Button(action: submitAuthForm) {
                        HStack(spacing: 6) {
                            Text(isSignUpMode ? "Create account" : "Sign in")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.foreground)
                    .foregroundStyle(DS.background)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(frontendStore.isAuthenticating || !isPrimaryButtonEnabled)

                    if frontendStore.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let authErrorMessage = frontendStore.authErrorMessage, !authErrorMessage.isEmpty {
                        Text(authErrorMessage)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DS.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 4) {
                        Text(isSignUpMode ? "Have an account?" : "No account?")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.mutedForeground)
                        Button(isSignUpMode ? "Sign in" : "Create one") {
                            isSignUpMode.toggle()
                            shouldRevealPassword = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.foreground)
                    }
                }
                .frame(maxWidth: 300)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(DS.background)
    }

    private var isPrimaryButtonEnabled: Bool {
        let normalizedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmailAddress.isEmpty, !normalizedPassword.isEmpty else {
            return false
        }
        if isSignUpMode {
            return acceptedTerms
        }
        return true
    }

    private func submitAuthForm() {
        let currentEmailAddress = emailAddress
        let currentPassword = password
        let currentDisplayName = displayName

        Task {
            if isSignUpMode {
                await frontendStore.signUp(
                    emailAddress: currentEmailAddress,
                    password: currentPassword,
                    displayName: currentDisplayName
                )
            } else {
                await frontendStore.signIn(
                    emailAddress: currentEmailAddress,
                    password: currentPassword
                )
            }
        }
    }

    private func handleGoogleButtonTap() {
        frontendStore.authErrorMessage = "Google sign-in is not wired yet. Use email/password."
    }

    @ViewBuilder
    private func labeledField(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DS.foreground)
            content()
        }
    }
}
