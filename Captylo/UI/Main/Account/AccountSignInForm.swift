import AppKit
import SwiftUI

/// Signing in to the Captylo account: an e-mail address and "Wyślij kod", then the six digits
/// from the e-mail with "Zaloguj", "Wróć" and "Wyślij ponownie". No passwords.
@MainActor
struct AccountSignInForm: View {
    let account: AccountStore

    @State private var email = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch account.state {
            case .codeSent(let address):
                codeStep(address)
            default:
                emailStep
            }
            if let error = account.lastError {
                ToolStatusLine(text: error, tone: .error)
            }
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .padding(.bottom, 4)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolCaption("Zaloguj się, żeby używać Captylo Pro: chmury i AI bez własnych kluczy.")
            HStack(spacing: 8) {
                TextField("Adres e-mail", text: $email, prompt: Text(verbatim: "twoj@email.pl"))
                    .textFieldStyle(.glass)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 320)
                    .onSubmit(sendCode)
                Button(action: sendCode) {
                    if account.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Wyślij kod")
                    }
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isBusy)
            }
        }
    }

    private func codeStep(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolCaption("Wysłałem kod na \(address). Sprawdź pocztę (także spam).")
            HStack(spacing: 8) {
                TextField("Kod z e-maila", text: $code, prompt: Text(verbatim: "123456"))
                    .textFieldStyle(.glass)
                    .textContentType(.oneTimeCode)
                    .font(GlassFont.body.monospacedDigit())
                    .frame(width: 140)
                    .onChange(of: code) { _, value in
                        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != value {
                            code = digits
                        }
                    }
                    .onSubmit(verify)
                Button(action: verify) {
                    if account.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Zaloguj")
                    }
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                .disabled(code.count != 6 || account.isBusy)
                Button("Wróć") {
                    code = ""
                    account.cancelCode()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(account.isBusy)
            }
            Button("Wyślij ponownie") {
                code = ""
                Task { await account.requestCode(email: address) }
            }
            .buttonStyle(.plain)
            .font(GlassFont.caption)
            .foregroundStyle(GlassColor.textSecondary)
            .underline()
            .disabled(account.isBusy)
        }
    }

    private func sendCode() {
        guard !account.isBusy else { return }
        let address = email
        Task { await account.requestCode(email: address) }
    }

    private func verify() {
        guard code.count == 6, !account.isBusy else { return }
        let digits = code
        Task {
            await account.verify(code: digits)
            if case .signedIn = account.state {
                code = ""
                email = ""
            }
        }
    }
}
