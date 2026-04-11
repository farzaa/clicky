import SwiftUI

struct LoginView: View {
    var onContinue: () -> Void

    @State private var isSignUp = false
    @State private var showPassword = false
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var rememberMe = false
    @State private var agreeTerms = false

    var body: some View {
        // No ScrollView — layout is sized to fit one menu-bar panel without scrolling.
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                CursorMarkView(size: 28)

                VStack(spacing: 4) {
                    Text(isSignUp ? "Create an account" : "Welcome to Debil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.foreground)
                        .multilineTextAlignment(.center)

                    Text(
                        isSignUp
                            ? "Tag what you know—and what you missed."
                            : "Bridge gaps from what you already know."
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: 280)
                }

                VStack(spacing: 8) {
                    Button(action: onContinue) {
                        HStack(spacing: 6) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 13))
                            Text(isSignUp ? "Continue with Google" : "Sign in with Google")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    HStack {
                        Rectangle().fill(DS.border).frame(height: 1)
                        Text(isSignUp ? "or sign up with email" : "or sign in with email")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.mutedForeground)
                        Rectangle().fill(DS.border).frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if isSignUp {
                            labeledField(title: "Username", content: {
                                TextField("Username", text: $username)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(6)
                                    .background(DS.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border))
                            })
                        }

                        labeledField(title: "Email", content: {
                            HStack(spacing: 6) {
                                Image(systemName: "envelope")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.foreground.opacity(0.75))
                                TextField("Email", text: $email)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                            }
                            .padding(6)
                            .background(DS.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border))
                        })

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Password")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.foreground)
                                Spacer()
                                if !isSignUp {
                                    Button("Forgot?") {}
                                        .buttonStyle(.plain)
                                        .font(.system(size: 9))
                                        .foregroundStyle(DS.mutedForeground)
                                }
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "lock")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.foreground.opacity(0.75))
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $password)
                                    } else {
                                        SecureField("Password", text: $password)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
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

                        if isSignUp {
                            Toggle(isOn: $agreeTerms) {
                                Text("I agree to Terms")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.foreground)
                            }
                            .toggleStyle(.checkbox)
                        } else {
                            Toggle(isOn: $rememberMe) {
                                Text("Remember 30 days")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.foreground)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    Button(action: onContinue) {
                        HStack(spacing: 6) {
                            Text(isSignUp ? "Create account" : "Sign in")
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

                    HStack(spacing: 4) {
                        Text(isSignUp ? "Have an account?" : "No account?")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.mutedForeground)
                        Button(isSignUp ? "Sign in" : "Create one") {
                            isSignUp.toggle()
                            showPassword = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.foreground)
                    }
                }
                .frame(maxWidth: 288)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func labeledField(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DS.foreground)
            content()
        }
    }
}
