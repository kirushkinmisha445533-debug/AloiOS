import SwiftUI
import UIKit

struct AuthView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var step: AuthStep = .email
    @FocusState private var focusedField: AuthStep?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        Spacer(minLength: 74)

                        if isVerification {
                            verificationStep
                        } else {
                            stepContent
                        }

                        statusMessages
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 132)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActions
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background {
                    LinearGradient(
                        colors: [
                            Color(uiColor: .systemBackground).opacity(0),
                            Color(uiColor: .systemBackground).opacity(0.96),
                            Color(uiColor: .systemBackground)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
        }
        .animation(.smooth(duration: 0.24), value: step)
        .animation(.smooth(duration: 0.24), value: app.authModeKey)
        .onAppear {
            normalizeStepForMode()
        }
        .onChange(of: app.authMode) { _, _ in
            normalizeStepForMode()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if canShowBackButton {
                Button(action: handleBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
            }

            Text("Alo")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(Color.primary)

            Spacer()

            Text(modeTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .frame(height: 44)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepIndicator

            VStack(alignment: .leading, spacing: 10) {
                Text(step.title(for: app.authMode))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.subtitle(for: app.authMode))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            authField(for: step)
                .focused($focusedField, equals: step)
                .submitLabel(step == stepsForCurrentMode.last ? .done : .next)
                .onSubmit(advance)
        }
        .id("step-\(app.authModeKey)-\(step)")
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var verificationStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepIndicator

            VStack(alignment: .leading, spacing: 10) {
                Text("Введите код")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text(app.notice.ifBlank("Мы отправили код на указанную почту."))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            authField(for: .code)
                .focused($focusedField, equals: .code)
                .submitLabel(.done)
                .onSubmit(app.submitAuth)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(indicatorSteps, id: \.self) { item in
                Capsule()
                    .fill(item == currentIndicatorStep ? AloTheme.accent : Color(uiColor: .tertiarySystemFill))
                    .frame(width: item == currentIndicatorStep ? 26 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.22), value: currentIndicatorStep)
    }

    private var bottomActions: some View {
        VStack(spacing: 14) {
            AuthPrimaryButton(
                title: bottomButtonTitle,
                disabled: app.isBusy || !canSubmitCurrentStep,
                busy: app.isBusy,
                action: {
                    if isVerification {
                        app.submitAuth()
                    } else {
                        advance()
                    }
                }
            )

            if !isVerification {
                Button(action: switchMode) {
                    HStack(spacing: 4) {
                        Text(app.authMode == .register ? "Уже есть аккаунт?" : "Нет аккаунта?")
                            .foregroundStyle(Color.secondary)
                        Text(app.authMode == .register ? "Войти" : "Создать")
                            .foregroundStyle(AloTheme.accent)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if !app.notice.isEmpty && !isVerification {
            AuthStatusRow(text: app.notice, tint: AloTheme.accent, systemImage: "checkmark.circle.fill")
        }

        if !app.errorMessage.isEmpty {
            AuthStatusRow(text: app.errorMessage, tint: Color(red: 1, green: 0.27, blue: 0.36), systemImage: "exclamationmark.circle.fill")
        }
    }

    @ViewBuilder
    private func authField(for step: AuthStep) -> some View {
        Group {
            if step == .password {
                SecureField(step.placeholder, text: binding(for: step))
            } else {
                TextField(step.placeholder, text: binding(for: step))
            }
        }
        .textInputAutocapitalization(step == .name ? .words : .never)
        .autocorrectionDisabled(step != .name)
        .keyboardType(step.keyboardType)
        .textContentType(step.textContentType)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(Color.primary)
        .tint(AloTheme.accent)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(focusedField == step ? AloTheme.accent.opacity(0.75) : Color.clear, lineWidth: 1.25)
        )
    }

    private var isVerification: Bool {
        app.authMode == .verifyLogin || app.authMode == .verifyEmail
    }

    private var stepsForCurrentMode: [AuthStep] {
        app.authMode == .register ? [.name, .username, .email, .password] : [.email, .password]
    }

    private var indicatorSteps: [AuthStep] {
        isVerification ? [.email, .password, .code] : stepsForCurrentMode
    }

    private var currentIndicatorStep: AuthStep {
        isVerification ? .code : step
    }

    private var modeTitle: String {
        if isVerification { return "Проверка" }
        return app.authMode == .register ? "Регистрация" : "Вход"
    }

    private var bottomButtonTitle: String {
        if isVerification { return "Продолжить" }
        if step == stepsForCurrentMode.last {
            return app.authMode == .register ? "Создать аккаунт" : "Войти"
        }
        return "Продолжить"
    }

    private var canShowBackButton: Bool {
        isVerification || canGoBack
    }

    private var canGoBack: Bool {
        guard let index = stepsForCurrentMode.firstIndex(of: step) else { return false }
        return index > 0
    }

    private var canSubmitCurrentStep: Bool {
        isVerification ? isStepValid(.code) : isStepValid(step)
    }

    private func isStepValid(_ step: AuthStep) -> Bool {
        switch step {
        case .name:
            return !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .username:
            return !app.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .email:
            return app.email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
        case .password:
            return app.password.count >= 6
        case .code:
            return !app.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func advance() {
        app.errorMessage = ""
        guard isStepValid(step) else { return }
        guard let index = stepsForCurrentMode.firstIndex(of: step) else { return }

        if index < stepsForCurrentMode.count - 1 {
            withAnimation(.smooth(duration: 0.24)) {
                step = stepsForCurrentMode[index + 1]
                focusedField = step
            }
        } else {
            app.submitAuth()
        }
    }

    private func handleBack() {
        if isVerification {
            backFromVerification()
        } else {
            goBack()
        }
    }

    private func goBack() {
        guard let index = stepsForCurrentMode.firstIndex(of: step), index > 0 else { return }
        app.errorMessage = ""
        withAnimation(.smooth(duration: 0.24)) {
            step = stepsForCurrentMode[index - 1]
            focusedField = nil
        }
    }

    private func backFromVerification() {
        app.code = ""
        app.notice = ""
        app.errorMessage = ""
        withAnimation(.smooth(duration: 0.24)) {
            app.authMode = app.name.isEmpty && app.username.isEmpty ? .login : .register
            normalizeStepForMode()
        }
    }

    private func switchMode() {
        withAnimation(.smooth(duration: 0.24)) {
            app.authMode = app.authMode == .register ? .login : .register
            app.errorMessage = ""
            app.notice = ""
            app.code = ""
            step = app.authMode == .register ? .name : .email
            focusedField = nil
        }
    }

    private func normalizeStepForMode() {
        guard !isVerification else {
            focusedField = nil
            return
        }
        let steps = stepsForCurrentMode
        if !steps.contains(step) {
            step = steps[0]
        }
        focusedField = nil
    }

    private func binding(for step: AuthStep) -> Binding<String> {
        switch step {
        case .name:
            return $app.name
        case .username:
            return $app.username
        case .email:
            return $app.email
        case .password:
            return $app.password
        case .code:
            return $app.code
        }
    }
}

private struct AuthPrimaryButton: View {
    let title: String
    let disabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .tint(.white)
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(disabled ? Color(uiColor: .tertiarySystemFill) : AloTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }
}

private struct AuthStatusRow: View {
    let text: String
    let tint: Color
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum AuthStep: Hashable {
    case name
    case username
    case email
    case password
    case code

    var placeholder: String {
        switch self {
        case .name:
            return "Имя"
        case .username:
            return "username"
        case .email:
            return "name@example.com"
        case .password:
            return "Пароль"
        case .code:
            return "Код из письма"
        }
    }

    var keyboardType: UIKeyboardType {
        switch self {
        case .email:
            return .emailAddress
        case .code:
            return .numberPad
        default:
            return .default
        }
    }

    var textContentType: UITextContentType? {
        switch self {
        case .name:
            return .name
        case .username:
            return .username
        case .email:
            return .emailAddress
        case .password:
            return .password
        case .code:
            return .oneTimeCode
        }
    }

    func title(for mode: AloAppModel.AuthMode) -> String {
        switch self {
        case .name:
            return "Как вас зовут?"
        case .username:
            return "Выберите имя пользователя"
        case .email:
            return mode == .register ? "Укажите почту" : "Введите почту"
        case .password:
            return mode == .register ? "Создайте пароль" : "Введите пароль"
        case .code:
            return "Введите код"
        }
    }

    func subtitle(for mode: AloAppModel.AuthMode) -> String {
        switch self {
        case .name:
            return "Имя будет видно в профиле, ленте и чатах."
        case .username:
            return "Короткий адрес, по которому вас смогут найти."
        case .email:
            return mode == .register ? "На нее придет код подтверждения." : "Мы найдем аккаунт и отправим код входа."
        case .password:
            return mode == .register ? "Минимум 6 символов." : "После пароля подтвердим вход кодом из письма."
        case .code:
            return "Код отправлен на почту."
        }
    }
}

private extension AloAppModel {
    var authModeKey: String {
        switch authMode {
        case .login:
            return "login"
        case .register:
            return "register"
        case .verifyLogin:
            return "verify-login"
        case .verifyEmail:
            return "verify-email"
        }
    }
}
