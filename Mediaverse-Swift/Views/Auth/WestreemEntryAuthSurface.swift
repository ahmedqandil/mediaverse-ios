import SwiftUI

/// Design System 24-B/24-C/24-D mobile entry surface.
///
/// This view owns the exact visual state machine only. Authentication and
/// session authority are injected so it cannot silently fall back to the
/// retired magic-link flow or create a second account implementation.
struct WestreemEntryAuthChallenge: Equatable, Sendable {
    let challengeID: String
    let resendAfter: TimeInterval
}

struct WestreemEntryAuthSurface: View {
    let reason: String?
    let continueWithApple: @MainActor () async throws -> Void
    let continueWithGoogle: @MainActor () async throws -> Void
    let requestCode: @MainActor (String) async throws -> WestreemEntryAuthChallenge
    let verifyCode: @MainActor (_ challengeID: String, _ email: String, _ code: String) async throws -> Void
    let authenticated: @MainActor () -> Void

    @State private var step: Step = .email
    @State private var email = ""
    @State private var digits = ["", "", "", ""]
    @State private var challenge: WestreemEntryAuthChallenge?
    @State private var resendAvailableAt: Date?
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var focusedDigit: Int?

    private enum Step { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                brand
                switch step {
                case .email: emailStep
                case .code: codeStep
                }
                Text("ONE ACCOUNT ACROSS PHONE, WEB AND TV")
                    .font(WestreemTokens.Typography.monoSmall)
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .tracking(1.1)
                    .frame(maxWidth: .infinity)
                    .padding(.top, WestreemTokens.Spacing.xl)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, WestreemTokens.Spacing.xl)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(WestreemTokens.Palette.ink950.ignoresSafeArea())
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("westreem-entry-auth-24-b-24-c-24-d")
    }

    private var brand: some View {
        HStack(spacing: WestreemTokens.Spacing.m) {
            Image("westreem-mark")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            Text("WeStreem")
                .font(WestreemTokens.Typography.title)
        }
        .padding(.bottom, WestreemTokens.Spacing.xxl)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in")
                .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 28, relativeTo: .title))
            Text(reason ?? "No password. One account across phone, web and TV.")
                .font(WestreemTokens.Typography.caption)
                .foregroundStyle(WestreemTokens.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WestreemTokens.Spacing.s)

            VStack(spacing: WestreemTokens.Spacing.m) {
                providerButton("Continue with Apple", systemImage: "apple.logo") {
                    try await continueWithApple()
                }
                providerButton("Continue with Google", systemImage: "g.circle.fill") {
                    try await continueWithGoogle()
                }
            }
            .padding(.top, WestreemTokens.Spacing.xl)

            HStack(spacing: WestreemTokens.Spacing.m) {
                Rectangle().fill(WestreemTokens.Palette.lineSoft).frame(height: 1)
                Text("OR")
                    .font(WestreemTokens.Typography.monoSmall)
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                Rectangle().fill(WestreemTokens.Palette.lineSoft).frame(height: 1)
            }
            .padding(.vertical, 20)

            Text("EMAIL")
                .font(WestreemTokens.Typography.monoSmall)
                .foregroundStyle(WestreemTokens.Palette.muted)
                .tracking(1.2)
            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
                .font(WestreemTokens.Typography.caption)
                .tint(WestreemTokens.Palette.green)
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .frame(minHeight: 48)
                .background(WestreemTokens.Palette.surfaceSunken)
                .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row).stroke(WestreemTokens.Palette.lineHard))
                .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row))
                .padding(.top, WestreemTokens.Spacing.s)

            inlineError

            Button {
                Task { await sendCode() }
            } label: {
                Group {
                    if busy { ProgressView().tint(WestreemTokens.Palette.greenOn) }
                    else { Text("Send me a code") }
                }
                .font(WestreemTokens.Typography.bodyEmphasized)
                .foregroundStyle(WestreemTokens.Palette.greenOn)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(WestreemTokens.Palette.green)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .padding(.top, WestreemTokens.Spacing.l)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter the code")
                .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 28, relativeTo: .title))
            Text("Sent to \(email). It expires in 10 minutes.")
                .font(WestreemTokens.Typography.caption)
                .foregroundStyle(WestreemTokens.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WestreemTokens.Spacing.s)

            HStack(spacing: WestreemTokens.Spacing.m) {
                ForEach(digits.indices, id: \.self) { index in
                    TextField("", text: Binding(
                        get: { digits[index] },
                        set: { updateDigit(index, $0) }
                    ))
                    .keyboardType(.numberPad)
                    .textContentType(index == 0 ? .oneTimeCode : nil)
                    .multilineTextAlignment(.center)
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 24, relativeTo: .title2))
                    .focused($focusedDigit, equals: index)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(WestreemTokens.Palette.surfaceSunken)
                    .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row).stroke(focusedDigit == index ? WestreemTokens.Palette.green : WestreemTokens.Palette.lineHard))
                    .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row))
                    .accessibilityLabel("Code digit \(index + 1)")
                }
            }
            .padding(.top, WestreemTokens.Spacing.xl)

            inlineError

            Button {
                Task { await submitCode() }
            } label: {
                Group {
                    if busy { ProgressView().tint(WestreemTokens.Palette.greenOn) }
                    else { Text("Continue") }
                }
                .font(WestreemTokens.Typography.bodyEmphasized)
                .foregroundStyle(WestreemTokens.Palette.greenOn)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(WestreemTokens.Palette.green)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || digits.contains(where: \.isEmpty))
            .opacity(busy || digits.contains(where: \.isEmpty) ? 0.4 : 1)
            .padding(.top, WestreemTokens.Spacing.l)

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button(resendLabel(at: context.date)) { Task { await sendCode() } }
                        .disabled(busy || !canResend(at: context.date))
                }
                Spacer()
                Button("USE A DIFFERENT EMAIL") {
                    step = .email
                    digits = ["", "", "", ""]
                    errorMessage = nil
                }
            }
            .font(WestreemTokens.Typography.monoSmall)
            .foregroundStyle(WestreemTokens.Palette.muted)
            .tracking(0.8)
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
    }

    private func providerButton(
        _ title: String,
        systemImage: String,
        action: @escaping @MainActor () async throws -> Void
    ) -> some View {
        Button {
            Task { await perform(action) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(WestreemTokens.Typography.bodyEmphasized)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    LinearGradient(
                        colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(Capsule().stroke(WestreemTokens.Palette.lineHard))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private var inlineError: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(WestreemTokens.Typography.small)
                .foregroundStyle(WestreemTokens.Palette.pink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WestreemTokens.Spacing.s)
                .accessibilityLabel("Sign-in error: \(errorMessage)")
        }
    }

    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do { try await action() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func sendCode() async {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let value = try await requestCode(normalized)
            email = normalized
            challenge = value
            resendAvailableAt = Date().addingTimeInterval(value.resendAfter)
            digits = ["", "", "", ""]
            step = .code
            focusedDigit = 0
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func submitCode() async {
        guard let challenge, digits.allSatisfy({ $0.count == 1 }), !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            try await verifyCode(challenge.challengeID, email, digits.joined())
            C.lightHaptic()
            authenticated()
        } catch {
            errorMessage = error.localizedDescription
            focusedDigit = 0
        }
    }

    private func updateDigit(_ index: Int, _ value: String) {
        let digit = value.filter(\.isNumber).suffix(1)
        digits[index] = String(digit)
        if !digit.isEmpty, index < digits.count - 1 { focusedDigit = index + 1 }
    }

    private func canResend(at date: Date) -> Bool {
        guard let resendAvailableAt else { return true }
        return date >= resendAvailableAt
    }

    private func resendLabel(at date: Date) -> String {
        guard let resendAvailableAt else { return "RESEND CODE" }
        let seconds = max(0, Int(ceil(resendAvailableAt.timeIntervalSince(date))))
        return seconds > 0 ? "RESEND IN 0:\(String(format: "%02d", seconds))" : "RESEND CODE"
    }
}
